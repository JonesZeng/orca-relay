---
name: deploy-orca-relay
description: Deploy Orca Relay end to end for an operator who has a Linux VPS and optionally their own domain — VPS relay service behind TLS, runtime-side bridge, client-side proxy, pairing-code rewrite, and the local stability layer. Use when the user asks to install, deploy, set up, or harden orca-relay on a VPS, or says "one-click deploy orca-relay".
---

# Deploy Orca Relay (agent runbook)

You are deploying a three-process path so an Orca CLI on one machine can reach an
Orca runtime on another machine through a VPS:

```text
Orca CLI -> orca-relay-proxy (client host) -> wss://<relay-domain>/ws  (VPS: orca-relay)
         -> orca-relay-bridge (runtime host) -> local Orca runtime WebSocket
```

The relay forwards opaque WebSocket payload bytes inside adapter frames. It does
not patch Orca, inspect application payloads, or add an encryption layer of its
own — transport privacy comes entirely from the TLS reverse proxy in front of it.

Work in phases. Each phase ends with a verification gate. **Do not start a phase
until the previous gate passed.** If a gate fails, fix that layer before moving
on; do not compensate downstream.

If the operator also needs Win/Mac/Mobile pairing-code clients (not only VPS
install + one CLI proxy), continue with
`skills/configure-orca-relay-clients/SKILL.md` after Gate 3. That skill covers
public proxies, `orca serve` pairing scopes, and per-platform client steps.

## Phase 0 — Interview, then plan

Ask the operator these questions before running anything. Do not guess.

1. **VPS access** — SSH host or alias, and whether `sudo`/root is available.
   Confirm `systemd` and either `x86_64` or `aarch64` (`uname -m`).
2. **Domain** — do they have a hostname they control that can point at this VPS?
   If yes, which DNS provider, and is a proxying CDN (e.g. Cloudflare orange
   cloud) in front of it?
3. **Runtime host** — which machine runs the Orca runtime, on what port
   (commonly `6768`), and is it headless (needs `Xvfb`) or a desktop session?
4. **Client host** — which machine runs Orca CLI.
5. **Version** — a published release tag to download, or build from source.

Then state the chosen topology back to the operator and get confirmation:

| Topology | When | Public endpoint |
| --- | --- | --- |
| **A. Domain + managed Caddy** (recommended) | Operator controls a hostname | `wss://<your-relay-domain.example>/ws` |
| **B. Operator-managed TLS** | Nginx/Caddy/Traefik already terminates TLS | `wss://<your-relay-domain.example>/ws` via their vhost |
| **C. No domain, SSH tunnel** | No hostname available | `ws://127.0.0.1:<local-port>/ws` forwarded over SSH |

**Hard constraint that decides B vs C:** the proxy and bridge validate TLS
against the bundled webpki root store. There is no flag to trust a private CA or
a self-signed certificate. So a publicly trusted certificate is required for any
`wss://` endpoint, which in practice requires a real hostname. If the operator
has no domain, do **not** expose plaintext `ws://` on the public internet — use
topology C, or help them obtain a free subdomain and switch to topology A.

## Phase 1 — Install the relay on the VPS

Preview first. `render` and `--dry-run` need no root and print secrets redacted:

```sh
curl -fsSL "https://raw.githubusercontent.com/JonesZeng/orca-relay/<tag>/scripts/install-vps.sh" \
  | bash -s -- render --domain '<your-relay-domain.example>' --bind '127.0.0.1:8080'
```

Show the rendered env file, systemd unit, and Caddy site to the operator. Only
then install:

```sh
# Topology A — installer manages the Caddy site and TLS
curl -fsSL "https://raw.githubusercontent.com/JonesZeng/orca-relay/<tag>/scripts/install-vps.sh" \
  | sudo bash -s -- install \
      --domain '<your-relay-domain.example>' \
      --bind '127.0.0.1:8080' \
      --version '<tag>' \
      --caddy-mode managed

# Topologies B and C — operator owns the reverse proxy, or there is none
curl -fsSL "https://raw.githubusercontent.com/JonesZeng/orca-relay/<tag>/scripts/install-vps.sh" \
  | sudo bash -s -- install \
      --bind '127.0.0.1:8080' \
      --version '<tag>' \
      --caddy-mode skip
```

What the installer manages: `/opt/orca-relay/` releases plus a `current`
symlink, `/etc/orca-relay/orca-relay.env`,
`/etc/systemd/system/orca-relay.service`, an optional
`/etc/caddy/conf.d/orca-relay.caddy`, and rollback snapshots under
`/var/lib/orca-relay/`. Release assets are downloaded as
`orca-relay-<tag>-<target>.tar.gz` and checksum-verified when the release
publishes `.sha256`.

Token handling — non-negotiable:

- Never pass a token as a CLI flag. The installer rejects `--token` on purpose.
- With no token source, the installer generates one and writes it only to the
  env file. That is the preferred path.
- To reuse an existing token: `sudo env ORCA_RELAY_TOKEN_FILE=/root/orca-relay-token bash -s -- install ...`
- Read the token back only when a later phase needs it, and never echo it into
  chat, logs, commit messages, or a PR body.

Pipe-to-root requires trust. Offer the operator the auditable alternative: pin
the tag, download `scripts/install-vps.sh`, read it, then run it locally.

**Gate 1** — on the VPS:

```sh
systemctl is-active orca-relay.service      # expect: active
curl -fsS 'http://127.0.0.1:8080/health'    # expect: {"status":"ok"}
ss -ltnp | grep 8080                        # expect: 127.0.0.1:8080 only, never 0.0.0.0
```

For topology A, also from anywhere: `curl -fsS 'https://<your-relay-domain.example>/health'`.

If the public check fails while the loopback check passes, the fault is DNS, the
certificate, or the reverse-proxy upstream — not the relay. With Cloudflare,
baseline DNS-only (grey cloud) before trying proxied mode.

## Phase 2 — Bridge on the runtime host

Pick a stable `server-id` (any opaque string, e.g. `<server-id>`). Persist the
relay identity in a root-only env file so no secret reaches a command line:

```sh
sudo install -d -m 0700 /root/.config/orca
sudo tee /root/.config/orca/orca-relay.env >/dev/null <<'EOF'
ORCA_RELAY_URL=wss://<your-relay-domain.example>/ws
ORCA_RELAY_SERVER_ID=<server-id>
ORCA_RELAY_TOKEN=<relay-token-from-secure-env>
ORCA_RUNTIME_WS_URL=ws://127.0.0.1:<orca-runtime-port>/
EOF
sudo chmod 600 /root/.config/orca/orca-relay.env
```

Start the runtime, then the bridge. On a headless host the runtime needs a
display and a supervisor that outlives your shell:

```sh
tmux new-session -d -s orca-xvfb -- /usr/bin/Xvfb :99 -screen 0 1280x720x24 -nolisten tcp
tmux new-session -d -s orca-server-relay \
  "exec env DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 orca serve --port <orca-runtime-port> --json >>/tmp/orca-serve-relay.log 2>&1"

tmux new-session -d -s orca-relay-bridge \
  "set -a; source /root/.config/orca/orca-relay.env; set +a; exec /opt/orca-relay/current/orca-relay-bridge \
     --relay-url \"\$ORCA_RELAY_URL\" --runtime-url \"\$ORCA_RUNTIME_WS_URL\" --server-id \"\$ORCA_RELAY_SERVER_ID\" \
     >>/tmp/orca-relay-bridge.log 2>&1"
```

Sourcing the env file inside the session keeps the token out of `ps` output.

**Gate 2** — the bridge process exists and holds an established connection to
the relay's public port; the runtime port is listening:

```sh
ss -ltn | grep '<orca-runtime-port>'
pgrep -af orca-relay-bridge
ss -tnp | grep orca-relay-bridge | grep ':443'   # topology A
```

Close code `1013` with reason `local runtime unavailable` means the bridge
reached the relay but could not reach the runtime — fix `ORCA_RUNTIME_WS_URL`.

## Phase 3 — Proxy and pairing on the client host

For topology C, first forward the loopback relay over SSH and use the local
endpoint as the relay URL:

```sh
ssh -N -L 8080:127.0.0.1:8080 <vps-host>
# then ORCA_RELAY_URL=ws://127.0.0.1:8080/ws
```

Run the proxy with an explicit bind so the pairing endpoint stays stable across
restarts (the default `127.0.0.1:0` picks a random port):

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='<server-id>'
export ORCA_RELAY_CLIENT_ID='<client-id>'
export ORCA_RELAY_TOKEN='<relay-token-from-secure-env>'

orca-relay-proxy --bind '127.0.0.1:17777' \
  --relay-url "$ORCA_RELAY_URL" --server-id "$ORCA_RELAY_SERVER_ID" --client-id "$ORCA_RELAY_CLIENT_ID"
```

Rewrite the pairing code so Orca CLI dials the local proxy instead of the
original endpoint. Only the endpoint changes; every other pairing field is
preserved:

```sh
orca-relay rewrite-pairing-code --endpoint 'ws://127.0.0.1:17777/ws' '<pairing-code-or-link>'
```

Accepted inputs are a bare URL-safe base64 pairing payload, an `orca://pair?...`
link, or an Orca Desktop browser URL containing `#pairing=`.

**Gate 3** — Orca CLI pairs through the rewritten code and completes one real
round trip. Nothing before this proves an end-to-end session; process health and
`/health` can both be green while the session is unusable.

## Phase 4 — Stability layer on the runtime host

This is what keeps an unattended deployment alive. Install it once Gate 3 passes.

```sh
# Auto-repair loop: restarts the local runtime and/or bridge, never remote proxies
bash scripts/orca-relay-bridge-watchdog.sh --status --json

# Supervise that loop as a detached singleton so it survives SSH/tmux exit
bash scripts/orca-relay-watchdog-daemon.sh start
bash scripts/orca-relay-watchdog-daemon.sh status    # expect: running pid=<pid>

# Evidence-only probe for wedged sessions; safe to leave running
bash scripts/orca-relay-soft-death-probe.sh --loop
```

Point the scripts at this deployment with `ORCA_*` overrides rather than editing
them: `ORCA_RELAY_ENV_FILE`, `ORCA_RELAY_BRIDGE_PATH`, `ORCA_CLI_BIN`,
`ORCA_APP_EXECUTABLE`, `ORCA_RUNTIME_PORT`, `ORCA_RELAY_HEALTH_URL`,
`ORCA_MOBILE_PAIRING_ADDRESS`. Run `--help` on each script for the full list.

Why both layers: process-level health can stay green while the relay session is
soft-dead. The watchdog reacts to a missing runtime port, a missing bridge, a
bridge with no established uplink socket, and a stalled uplink (high `Send-Q`
with flat `bytes_sent`). The probe never restarts anything — it freezes evidence
so a post-mortem is possible.

Use `scripts/restart-orca-relay-mobile.sh` only when the operator intentionally
wants to bounce the remote units too; the watchdog deliberately never does.

## Failure → fix

| Symptom | Layer | Fix |
| --- | --- | --- |
| `missing ORCA_RELAY_TOKEN` | Environment | Set it in the env file or shell. There is no `--token` flag. |
| WebSocket upgrade `401` | Auth | Relay, proxy, and bridge must share the exact same token. |
| WebSocket upgrade `503` | Routing | No bridge registered for that `serverId`; start the bridge or fix the id mismatch. |
| Public `/health` fails, loopback works | Reverse proxy | Caddy/Nginx upstream must match `ORCA_RELAY_BIND`; check DNS and certificate. |
| Close `1013 local runtime unavailable` | Bridge→runtime | Start the Orca runtime or fix `ORCA_RUNTIME_WS_URL`. |
| Certificate rejected by proxy/bridge | TLS trust | Publicly trusted certificate required; no private-CA option exists. Switch to topology C. |
| Healthy processes, clients still hang | Soft death | `scripts/orca-relay-soft-death-probe.sh --once --json`; look for high `Send-Q`, flat `bytes_sent`, elevated `lastrcv`. |
| Runtime port down after reboot | Local runtime | `scripts/orca-relay-bridge-watchdog.sh --once`, and make the watchdog daemon start on boot. |

## Rollback

```sh
sudo bash scripts/install-vps.sh rollback              # restore the latest installer snapshot
sudo bash scripts/install-vps.sh uninstall             # stop and disable, keep config and state
sudo bash scripts/install-vps.sh uninstall --purge     # also remove config and state
```

## Rules you must not break

- Keep the Rust relay bound to loopback. Expose only `80/tcp` and `443/tcp`
  through the TLS reverse proxy. Never bind the relay to `0.0.0.0`.
- Relay tokens travel through `ORCA_RELAY_TOKEN` or `ORCA_RELAY_TOKEN_FILE`
  only — never a flag, never a command line, never chat output, never a commit.
- Treat pairing codes, `deviceToken`, and `publicKeyB64` as secrets.
- Do not claim capabilities the code does not have: there is no per-client
  token, no token expiry, no mTLS, no Origin allow-list, no rate limiting, no
  payload encryption, and no Orca RPC inspection.
- Report exactly which gates you ran and what they proved. A green `/health` is
  not evidence of a working Orca session.
