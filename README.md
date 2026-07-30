# Orca Relay

[English](README.md) | [简体中文](README.zh-CN.md)

![Orca Relay cover](assets/orca-relay-cover.png)

> Keep Orca CLI usable over a VPS relay without modifying the Orca app bundle.

Orca Relay is a small Rust adapter layer for Orca's existing short-lived WebSocket runtime flow. A remote Orca CLI connects to a local proxy, the proxy carries WebSocket messages through a VPS relay as opaque adapter frames, and a bridge near the desktop Orca runtime forwards those messages to the real local runtime.

The relay does **not** patch Orca, decode Orca RPCs, or inspect application payload bytes. It only provides a network path.

## Status and scope

Included:

- `orca-relay`: VPS WebSocket relay server with `/health` and `/ws`.
- `orca-relay-proxy`: local WebSocket proxy for the remote machine running Orca CLI.
- `orca-relay-bridge`: bridge near the desktop Orca runtime.
- `orca-relay rewrite-pairing-code`: helper that rewrites only a pairing-code endpoint.
- Local contract tests for relay routing, adapter frame forwarding, and pairing-code rewrite behavior.

Not included:

- No Orca app bundle modification.
- No Orca RPC parsing, payload inspection, payload encryption layer, or credential regeneration.
- No persistent client helper, connection pool, account system, rate limiting, audit log, or multi-tenant authorization.
- No crates.io/package-manager distribution yet; `Cargo.toml` has `publish = false`.

## How it works at a glance

![Excalidraw-style Orca Relay architecture diagram showing a remote Orca CLI, local proxy, VPS relay, bridge, and local Orca runtime exchanging opaque WebSocket frames.](assets/orca-relay-design-excalidraw.png)

```text
Remote machine                 VPS                       Desktop machine
Orca CLI -> local proxy  ->  relay /ws  ->  bridge  ->  local Orca runtime
          raw WS             adapter frames           raw WS
```

Typical runtime path:

1. `orca-relay-bridge` runs near the desktop Orca runtime and connects outward to the VPS relay as `role=server`.
2. `orca-relay-proxy` runs on the remote CLI machine and listens on a local WebSocket endpoint.
3. `orca-relay rewrite-pairing-code` changes the Orca pairing-code `endpoint` to the local proxy endpoint while preserving `deviceToken` and `publicKeyB64`.
4. Orca CLI connects to the local proxy as if it were the runtime.
5. The proxy and bridge wrap and restore WebSocket `text`, `binary`, and `close` messages while the VPS relay routes by `serverId` and `clientId`.

## Architecture

![Orca Relay data-flow schematic showing outbound and return WebSocket paths through a VPS relay, with payload bytes treated as opaque.](assets/orca-relay-flow.png)

### `orca-relay` server

`orca-relay` runs on a VPS behind TLS/reverse proxy infrastructure. It exposes:

- `GET /health`: unauthenticated health/version JSON.
- `GET /ws`: authenticated WebSocket relay endpoint.

`/ws` requires `Authorization: Bearer $ORCA_RELAY_TOKEN`, `v=1`, `serverId`, and one of:

- `role=server` for the bridge side;
- `role=client&clientId=<client-id>` for the proxy side.

The relay keeps one active server socket per `serverId` and routes client frames back by `clientId`. If a client connects before a matching server/bridge exists, it fails fast with service unavailable.

### `orca-relay-proxy`

`orca-relay-proxy` runs on the remote machine where Orca CLI runs. It:

- binds a local `/ws` endpoint;
- accepts the raw Orca CLI WebSocket;
- opens a relay connection as `role=client`;
- wraps each local WebSocket message into an adapter frame;
- restores bridge replies back into raw WebSocket messages for Orca CLI.

The relay token is read only from `ORCA_RELAY_TOKEN`.

### `orca-relay-bridge`

`orca-relay-bridge` runs on the desktop machine, or another host that can reach the local Orca runtime WebSocket. It:

- keeps one outbound relay connection open as `role=server`;
- opens one local Orca runtime WebSocket per relayed `connectionId`;
- forwards runtime replies back through the relay;
- closes the remote side with code `1013` and reason `local runtime unavailable` if it cannot reach the local runtime.

The relay token is read only from `ORCA_RELAY_TOKEN`.

## Adapter frame format

Every proxy/bridge payload carried through the relay is a binary adapter frame:

```text
[u32 big-endian header_len][header_json][opaque_payload]
```

The JSON header uses camelCase fields:

| Field | Meaning |
| --- | --- |
| `clientId` | Relay client identity used by server-side routing. |
| `connectionId` | End-to-end WebSocket connection identity used by proxy and bridge. |
| `direction` | `client_to_server` or `server_to_client`. |
| `opcode` | Original WebSocket message type: `text`, `binary`, or `close`. |
| `closeCode`, `closeReason` | Optional close metadata for close frames. |

The bytes after `header_json` are the original WebSocket payload bytes. The VPS relay parses only enough header metadata to route frames. It does not inspect, decrypt, transform, log, or make routing decisions from Orca application payload bytes.

## Quick start

You need three places:

1. **VPS relay**: runs `orca-relay` behind TLS.
2. **Desktop/runtime side**: runs `orca-relay-bridge` near the real Orca runtime.
3. **Remote CLI side**: runs `orca-relay-proxy` and points Orca CLI at its local endpoint.

Use one shared relay token across the relay, proxy, and bridge:

```sh
export ORCA_RELAY_TOKEN='<your-relay-token>'
```

`serverId` and `clientId` are routing identifiers, not secrets:

```sh
export ORCA_RELAY_SERVER_ID='desktop-orca'
export ORCA_RELAY_CLIENT_ID='remote-cli-1'
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
```

## Installation from GitHub releases

### Prebuilt binaries

GitHub release `v0.1.0` publishes a prebuilt Linux x86_64 tarball:

```text
orca-relay-v0.1.0-x86_64-unknown-linux-musl.tar.gz
orca-relay-v0.1.0-x86_64-unknown-linux-musl.tar.gz.sha256
```

Each archive contains:

- `orca-relay`
- `orca-relay-proxy`
- `orca-relay-bridge`

Future targets should use the same naming pattern: `orca-relay-v0.1.0-<target>.tar.gz`. Verify the checksum sidecar before unpacking:

```sh
TARGET='x86_64-unknown-linux-musl'
BASE_URL='https://github.com/JonesZeng/orca-relay/releases/download/v0.1.0'

curl -fLO "$BASE_URL/orca-relay-v0.1.0-$TARGET.tar.gz"
curl -fLO "$BASE_URL/orca-relay-v0.1.0-$TARGET.tar.gz.sha256"
sha256sum -c "orca-relay-v0.1.0-$TARGET.tar.gz.sha256"
tar -xzf "orca-relay-v0.1.0-$TARGET.tar.gz"
```

The VPS installer below uses the same release asset naming by default. Set `ORCA_RELAY_GITHUB_REPO=JonesZeng/orca-relay` only if you need to be explicit; it is already the installer default.

## VPS deployment

### Deploy with an agent

`skills/deploy-orca-relay/SKILL.md` is a self-contained deployment runbook written for a coding agent: it interviews you for the missing facts, picks a topology based on whether you own a domain, installs the VPS relay, brings up the bridge and proxy, rewrites the pairing code, and finishes by installing the local stability layer. Every phase ends in a verification gate the agent must show you.

Install it wherever your agent loads skills from — for example `.claude/skills/deploy-orca-relay/SKILL.md`, `.agents/skills/deploy-orca-relay/SKILL.md`, or `~/.agents/skills/deploy-orca-relay/SKILL.md`. If your agent has no skill mechanism, paste this prompt instead:

```text
Read skills/deploy-orca-relay/SKILL.md from the orca-relay repository and deploy Orca Relay for me.
I have a Linux VPS (ssh host: <vps-host>) and <a domain: your-relay-domain.example | no domain>.
My Orca runtime runs on <runtime-host> port <orca-runtime-port>; Orca CLI runs on <client-host>.
Interview me for anything missing, run the installer's `render` preview before any mutating
install, stop at every verification gate and show me the output, and never print the relay token.
```

The manual paths below are what that skill drives, and remain the reference if you would rather run each step yourself.

### One-command installer

For GitHub release `v0.1.0`, the intended VPS install path downloads a prebuilt `orca-relay-v0.1.0-<target>.tar.gz` asset from `JonesZeng/orca-relay`:

```sh
curl -fsSL "https://raw.githubusercontent.com/JonesZeng/orca-relay/v0.1.0/scripts/install-vps.sh" \
  | sudo bash -s -- install \
      --domain '<your-relay-domain.example>' \
      --bind '127.0.0.1:8080' \
      --version 'v0.1.0' \
      --caddy-mode managed
```

What the installer is expected to manage:

- `/opt/orca-relay/` release files and `current` symlink;
- `/etc/orca-relay/orca-relay.env` with `ORCA_RELAY_BIND`, `ORCA_RELAY_TOKEN`, and `RUST_LOG`;
- `/etc/systemd/system/orca-relay.service`;
- optional Caddy site that reverse-proxies the public domain to the loopback relay bind;
- rollback snapshots before mutating existing files.

Token handling:

- Do not pass the relay token as a CLI flag.
- Use `ORCA_RELAY_TOKEN_FILE=/root/orca-relay-token` when reusing an existing token.
- If no token source is supplied, the installer generates one locally and writes it only to the env file.
- Render and dry-run output must redact token material.

Example with an operator-supplied token file:

```sh
curl -fsSL "https://raw.githubusercontent.com/JonesZeng/orca-relay/v0.1.0/scripts/install-vps.sh" \
  | sudo env ORCA_RELAY_TOKEN_FILE='/root/orca-relay-token' \
      bash -s -- install \
        --domain '<your-relay-domain.example>' \
        --bind '127.0.0.1:8080' \
        --version 'v0.1.0' \
        --caddy-mode managed
```

If you already manage TLS/reverse proxy yourself:

```sh
curl -fsSL "https://raw.githubusercontent.com/JonesZeng/orca-relay/v0.1.0/scripts/install-vps.sh" \
  | sudo bash -s -- install \
      --bind '127.0.0.1:8080' \
      --version 'v0.1.0' \
      --caddy-mode skip
```

Pipe-to-root installers require trust. Pin the release tag, inspect `scripts/install-vps.sh`, or perform a manual install from the verified release artifacts above if you need an auditable path.

### Manual service layout

Recommended VPS files:

```text
/opt/orca-relay/current/orca-relay          # service binary
/etc/orca-relay/orca-relay.env             # root-managed env file
/etc/systemd/system/orca-relay.service     # systemd service
/etc/caddy/conf.d/orca-relay.caddy         # optional Caddy site
/var/lib/orca-relay/                       # state and installer snapshots
```

Environment file:

```dotenv
ORCA_RELAY_BIND=127.0.0.1:8080
ORCA_RELAY_TOKEN=<your-relay-token>
RUST_LOG=info
```

Caddy site example:

```caddyfile
<your-relay-domain.example> {
    encode zstd gzip

    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
    }
}
```

Keep the Rust relay bound to loopback. Expose only the TLS reverse proxy on public `80/tcp` and `443/tcp`.

Port note: older deployment notes for this work recorded a live origin at `127.0.0.1:6769`, while the checked-in env/Caddy templates and server default use `127.0.0.1:8080`. Either port is fine if intentional; `ORCA_RELAY_BIND`, the reverse-proxy upstream, and the running service must use the same loopback address.

## Bridge and proxy usage

### Start the desktop-side bridge

Run this on the desktop machine or LAN host that can reach the real Orca runtime WebSocket:

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='desktop-orca'
export ORCA_RUNTIME_WS_URL='ws://127.0.0.1:<orca-runtime-port>/ws'
export ORCA_RELAY_TOKEN='<your-relay-token>'

orca-relay-bridge
```

Equivalent command with non-secret values as flags:

```sh
orca-relay-bridge \
  --relay-url "$ORCA_RELAY_URL" \
  --runtime-url "$ORCA_RUNTIME_WS_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID"
```

### Start the remote-side proxy

Run this on the machine where Orca CLI will run:

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='desktop-orca'
export ORCA_RELAY_CLIENT_ID='remote-cli-1'
export ORCA_RELAY_BIND='127.0.0.1:17777'
export ORCA_RELAY_TOKEN='<your-relay-token>'

orca-relay-proxy
```

Equivalent command with non-secret values as flags:

```sh
orca-relay-proxy \
  --bind "$ORCA_RELAY_BIND" \
  --relay-url "$ORCA_RELAY_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID" \
  --client-id "$ORCA_RELAY_CLIENT_ID"
```

Use the printed local URL, normally `ws://127.0.0.1:17777/ws`, as the pairing-code endpoint.

## Pairing-code rewrite

Orca pairing codes carry an endpoint plus sensitive pairing material. The helper changes only the endpoint; it preserves `deviceToken` and `publicKeyB64` and validates pairing payload version `2`.

Supported input forms:

- bare URL-safe base64 pairing payload;
- `orca://pair?...` links;
- Orca Desktop browser URLs containing `#pairing=`.

Example:

```sh
orca-relay rewrite-pairing-code \
  --endpoint 'ws://127.0.0.1:17777/ws' \
  '<pairing-code-or-link>'
```

Do not paste real pairing codes, `deviceToken`, or `publicKeyB64` values into GitHub issues, logs, or screenshots.

## Security model

- `ORCA_RELAY_TOKEN` gates relay WebSocket access. It is environment-only; no relay binary accepts token CLI flags.
- Anyone with `ORCA_RELAY_TOKEN` can join the relay trust domain. The current code does not implement per-client tokens, token expiry, token hashing, mTLS, Origin allow-listing, rate limiting, or per-`serverId` authorization.
- Public relay traffic should use `wss://` through Caddy/Nginx or another TLS reverse proxy.
- The relay origin should stay on loopback.
- Payload bytes are opaque to Orca Relay. Opaque does not mean encrypted by this project.
- The pairing-code helper preserves Orca credential fields. Preservation is for compatibility; it is not a new security guarantee.

## Operations and latency checks

Health:

```sh
curl -fsS 'https://<your-relay-domain.example>/health'
curl -fsS 'http://127.0.0.1:8080/health'
```

Support scripts:

| Script | Purpose |
| --- | --- |
| `scripts/measure-relay-ws-latency.py` | Measures TCP, TLS, WebSocket open, and relay-frame round-trip phases. Requires `ORCA_RELAY_TOKEN` from the environment; no `--token` flag. |
| `scripts/cloudflare-relay-mode.sh` | Checks or switches Cloudflare DNS-only/proxied mode. Dry-run by default unless `--apply` is supplied. |
| `scripts/compare-cloudflare-relay-latency.sh` | Runs grey-vs-orange latency probes by composing the two scripts above. |
| `scripts/test_support_scripts.py` | Local checks for frame construction, token redaction, and helper script safety. |
| `scripts/orca-relay-soft-death-probe.sh` | Evidence-only soft-death probe. Samples TCP Send-Q / bytes / lastrcv and freezes local+remote snapshots on warn/crit. Never restarts services. |
| `scripts/orca-relay-bridge-watchdog.sh` | Local connectivity watchdog. Restarts the headless `orca serve` runtime and/or the bridge when the path is dead or soft-wedged. Does **not** bounce remote/public proxies. |
| `scripts/orca-relay-watchdog-daemon.sh` | Detached singleton supervisor for the watchdog loop. Uses `setsid` plus an `flock` lock so the loop survives terminal/tmux/SSH exit and cannot double-start. |
| `scripts/restart-orca-relay-mobile.sh` | Full operator restart: remote relay/proxy units + local Xvfb/Electron serve + pairing-code refresh + public health/WS checks. |

### Soft-death probe and local watchdog

Process-level health (`bridge pid` + `:443 ESTAB` + public `/health`) can stay green while the application session is already wedged. The soft-death tooling covers that gap:

```sh
# Evidence only (safe to leave running)
bash scripts/orca-relay-soft-death-probe.sh --once --json
bash scripts/orca-relay-soft-death-probe.sh --loop

# Local repair loop (never restarts remote proxies)
bash scripts/orca-relay-bridge-watchdog.sh --status --json
bash scripts/orca-relay-bridge-watchdog.sh --loop

# Same loop, detached and single-instance (survives terminal/tmux exit)
bash scripts/orca-relay-watchdog-daemon.sh start
bash scripts/orca-relay-watchdog-daemon.sh status
bash scripts/orca-relay-watchdog-daemon.sh stop

# Full manual restart of remote proxies + local runtime
bash scripts/restart-orca-relay-mobile.sh
```

Recommended operator split:

1. Keep `orca-relay-soft-death-probe.sh --loop` for evidence capture.
2. Keep `orca-relay-bridge-watchdog.sh --loop` for local auto-repair (runtime/bridge only), started through `orca-relay-watchdog-daemon.sh start` for anything unattended.
3. Use `restart-orca-relay-mobile.sh` only when you intentionally want to bounce the remote path too.

The current `orca serve` CLI accepts no relay arguments and does not parent a bridge, so the watchdog supervises the runtime and the bridge as two independent tmux services (`orca-server-relay` and `orca-relay-bridge` by default) and restarts only the one that failed.

All three scripts read the persisted relay identity from `ORCA_RELAY_ENV_FILE` (default `/root/.config/orca/orca-relay.env`) and accept `ORCA_*` overrides for bridge path, health URL, remote host, and thresholds. Defaults point at local development paths such as `target/release/orca-relay-bridge` and placeholders like `https://<your-relay-domain.example>/health`.

The public deployment fact captured during development was `wss://relay-orca.lucaszen.dpdns.org/ws` with Cloudflare DNS-only / grey cloud. Treat that as a deployment example, not a shared public service contract.

## Troubleshooting

| Symptom | Likely layer | What to check |
| --- | --- | --- |
| `missing ORCA_RELAY_TOKEN` | Process environment | Set `ORCA_RELAY_TOKEN` in the service env file or shell. Do not pass it as a flag. |
| WebSocket upgrade returns 401 | Relay auth | Relay, proxy, and bridge must use the exact same bearer token. |
| WebSocket upgrade returns 503 | No bridge for `serverId` | Start `orca-relay-bridge`; verify proxy and bridge use the same `ORCA_RELAY_SERVER_ID`. |
| Public `/health` fails but service is active | Reverse proxy / bind | Ensure Caddy `reverse_proxy` matches `ORCA_RELAY_BIND`. |
| Bridge connects but CLI gets no response | Local Orca runtime | Verify `ORCA_RUNTIME_WS_URL` is reachable from the bridge host. |
| Close code `1013`, reason `local runtime unavailable` | Bridge-to-runtime connection | Start Orca runtime or fix the bridge runtime URL. |
| Pairing rewrite fails | Pairing payload | Input must be supported shape, version `2`, and include `endpoint`, `deviceToken`, `publicKeyB64`. |
| CLI connects to wrong port | Proxy bind / pairing endpoint | Use the exact `ws://.../ws` endpoint printed by `orca-relay-proxy` or set a stable `--bind`. |
| Orange-cloud Cloudflare mode changes behavior | Cloudflare edge path | Baseline DNS-only/grey first; verify WebSocket and TLS settings separately before using orange mode. |
| `adapter text payload was not UTF-8` | Adapter opcode mismatch | Non-UTF-8 bytes must travel as WebSocket binary frames, not text frames. |
| Bridge process + `:443 ESTAB` look healthy, but clients hang | Soft-death / wedged session | Run `scripts/orca-relay-soft-death-probe.sh --once --json`. High Send-Q with flat `bytes_sent`, elevated `lastrcv`, or missing bridge `:443` are the main signals. |
| Local runtime port `:6768` is down after host reboot | Local headless serve | Use `scripts/orca-relay-bridge-watchdog.sh` (runtime repair) or `scripts/restart-orca-relay-mobile.sh` for a full restart. |

## Build from source

Use this as the fallback path when no prebuilt release asset matches your platform or when you need a local development build.

```sh
cargo build --release
```

Release binaries are:

- `target/release/orca-relay`
- `target/release/orca-relay-proxy`
- `target/release/orca-relay-bridge`

For static Linux builds, this repository may also contain local `target/x86_64-unknown-linux-musl/release/` outputs depending on how it was built. Do not rely on local `target/` paths in public release automation; publish explicit GitHub release assets and checksums.

## Verification

Contributor release gate:

```sh
cargo test && cargo fmt --check && cargo clippy --all-targets --all-features -- -D warnings && python3 scripts/test_support_scripts.py && python3 -m py_compile scripts/measure-relay-ws-latency.py scripts/test_support_scripts.py && bash -n scripts/cloudflare-relay-mode.sh scripts/compare-cloudflare-relay-latency.sh scripts/install-vps.sh scripts/orca-relay-bridge-watchdog.sh scripts/orca-relay-soft-death-probe.sh scripts/restart-orca-relay-mobile.sh
```

What this proves:

- Rust relay contract, adapter proxy/bridge contract, and pairing-code rewrite behavior pass locally.
- Rust sources are formatted and Clippy-clean under declared targets/features.
- Support scripts parse and keep token-handling guardrails locally.
- Shell scripts are syntactically valid.

What this does not prove by itself:

- the public relay URL is reachable right now;
- a real Orca Desktop bundle or live Orca CLI session was exercised;
- Cloudflare/DNS/TLS is configured correctly on a specific VPS;
- real latency measurements were taken.

## Repository structure

```text
orca-relay/
├── Cargo.toml
├── src/
│   ├── lib.rs
│   ├── main.rs
│   └── bin/
│       ├── orca-relay-proxy.rs
│       └── orca-relay-bridge.rs
├── tests/
│   ├── relay_contract.rs
│   ├── adapter_contract.rs
│   └── pairing_code.rs
├── scripts/
│   ├── install-vps.sh
│   ├── orca-relay.env.example
│   ├── orca-relay.service.template
│   ├── Caddyfile.orca-relay.template
│   ├── measure-relay-ws-latency.py
│   ├── cloudflare-relay-mode.sh
│   ├── compare-cloudflare-relay-latency.sh
│   ├── test_support_scripts.py
│   ├── orca-relay-soft-death-probe.sh
│   ├── orca-relay-bridge-watchdog.sh
│   ├── orca-relay-watchdog-daemon.sh
│   └── restart-orca-relay-mobile.sh
├── skills/
│   └── deploy-orca-relay/
│       └── SKILL.md
└── assets/
    ├── README.md
    └── prompts/
```

| Path | Purpose |
| --- | --- |
| `src/lib.rs` | Relay app, pairing-code rewrite logic, adapter frame codec, proxy/bridge runtime implementation. |
| `src/main.rs` | `orca-relay` server entrypoint and `rewrite-pairing-code` subcommand. |
| `src/bin/orca-relay-proxy.rs` | Remote-side local proxy CLI. |
| `src/bin/orca-relay-bridge.rs` | Runtime-side bridge CLI. |
| `scripts/` | Deployment templates, one-command VPS installer, and operations helpers. |
| `skills/deploy-orca-relay/SKILL.md` | Agent-executable deployment runbook for VPS operators, with or without their own domain. |
| `tests/` | Relay, adapter, and pairing-code contract tests. |
| `assets/prompts/` | Public-safe image-generation prompts for README diagrams. |
