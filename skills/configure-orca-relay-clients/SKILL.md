---
name: configure-orca-relay-clients
description: End-to-end agent runbook for a new user who needs Orca runtime + Orca Relay on a development host, a personal VPS relay path, and Win/Mac/Mobile pairing-code clients. Use when the user asks how to set up orca server with orca-relay, how to pair through a personal VPS, how agents should configure mobile/desktop clients, or when deploy-orca-relay alone is not enough because clients still cannot pair.
---

# Configure Orca server + Orca Relay for clients

You are configuring the **full remote-access path**, not only the VPS relay binary.

```text
Win / Mac / Mobile / remote CLI
        |
        |  pairing code (endpoint only is rewritten for relay)
        v
[public or local] orca-relay-proxy
        |
        |  adapter frames + shared ORCA_RELAY_TOKEN
        v
personal VPS: orca-relay  (/health, /ws behind TLS)
        |
        v
orca-relay-bridge  (role=server)
        |
        v
development host: orca serve / Orca runtime WebSocket
```

Read this skill **before inventing steps**. If the VPS relay is not installed yet, finish
`skills/deploy-orca-relay/SKILL.md` first (or run both skills in order: deploy VPS → this skill).

## What agents must get right

1. **Three process layers**, not one:
   - runtime host: `orca serve` (or desktop Orca) + `orca-relay-bridge`
   - personal VPS: `orca-relay` behind TLS; optionally a **public** `orca-relay-proxy`
   - client side: either a **local** `orca-relay-proxy` (CLI/dev) **or** a pairing code whose `endpoint` already points at the public proxy (mobile / remote desktop)
2. **Pairing codes are secrets.** Never print full pairing URLs, `deviceToken`, or `publicKeyB64` into chat, commits, logs, or screenshots. Show only redacted forms such as `orca://pair?code=<redacted>` and the rewritten **endpoint** string.
3. **`ORCA_RELAY_TOKEN` is environment-only.** No `--token` flag exists on relay/proxy/bridge/installer.
4. **Current public `orca serve` CLI does not take relay flags and does not parent the bridge.** Supervise runtime and bridge as two processes. Do not invent `--serve-relay-*` flags unless the operator’s local Electron build actually exposes them.
5. **Scope matters:**
   - Desktop / web / remote-runtime clients → `scope=runtime` (default `orca serve` pairing)
   - Mobile app → `scope=mobile` (`orca serve --mobile-pairing`, or Settings → Mobile QR)
6. **Endpoint rewrite only changes reachability.** `orca-relay rewrite-pairing-code` rewrites `endpoint` and preserves credential fields. Opaque relay frames are **not** an encryption product.

## Interview first (do not guess)

Ask the operator and restated topology back before writing files or restarting services:

| Question | Why it matters |
| --- | --- |
| Where does the Orca runtime run? (dev laptop, headless Linux box, desktop GUI) | Places `orca serve` + bridge |
| Runtime port? (common: `6768`) | Bridge `ORCA_RUNTIME_WS_URL` |
| Personal VPS SSH host + domain? | Relay public `wss://` |
| Is the VPS relay already healthy? | Gate before clients |
| Who will connect: Mobile, Mac desktop, Windows desktop, remote CLI, or all? | Chooses public proxy vs local proxy |
| One shared `serverId` for this runtime? | Must match bridge + every proxy |

Chosen identifiers (examples only):

```text
ORCA_RELAY_SERVER_ID=<server-id>          # routing id, not a secret
ORCA_RELAY_URL=wss://<your-relay-domain.example>/ws
ORCA_RUNTIME_WS_URL=ws://127.0.0.1:<orca-runtime-port>/   # or .../ws if that is what the runtime prints
ORCA_PUBLIC_PROXY_ENDPOINT=wss://<your-public-proxy-domain.example>/ws
```

Use one `serverId` per runtime. Give each public/local proxy its own `clientId`
(`mobile-public`, `macbook-cli`, `win-dev`, …).

## Topology cheat sheet

| Client | Recommended path | Pairing `endpoint` the client dials |
| --- | --- | --- |
| **Mobile (iOS/Android)** | Public proxy on VPS | `wss://<public-proxy-or-mobile-domain>/ws` |
| **Mac / Windows Orca desktop** (away from runtime host) | Public proxy on VPS **or** local proxy on that Mac/Win machine | public `wss://.../ws` **or** local `ws://127.0.0.1:17777/ws` |
| **Remote Orca CLI** on a Linux box / CI host | Local `orca-relay-proxy` on the CLI host | rewritten `ws://127.0.0.1:17777/ws` |
| **Same LAN only** (no VPS) | No orca-relay needed | `ws://<runtime-lan-ip>:6768` from `orca serve --pairing-address <lan-ip>` |

If the user asked for “personal VPS pairing”, use the relay path, not LAN-only.

---

## Phase A — Development / runtime host: Orca server + bridge

### A1. Start the Orca runtime

**Headless Linux / dev server (preferred for always-on relay):**

```sh
# Install/run path is operator-specific: packaged AppImage, orca-ide, or dev orca-dev.
# Public flags that exist today:
orca serve --port <orca-runtime-port> --json
```

For clients that must reach through the personal VPS public proxy, advertise that
public WebSocket endpoint in the pairing offer:

```sh
# Runtime-scoped pairing for Mac/Win/desktop/web clients
orca serve \
  --port <orca-runtime-port> \
  --pairing-address 'wss://<your-public-proxy-domain.example>/ws' \
  --json

# Mobile-scoped pairing for the phone app
orca serve \
  --port <orca-runtime-port> \
  --pairing-address 'wss://<your-public-proxy-domain.example>/ws' \
  --mobile-pairing \
  --json
```

Notes:

- `--pairing-address` **only changes the advertised endpoint inside the pairing code**. It does not bind the public socket by itself.
- On headless hosts without `DISPLAY`, install `xvfb` first. Current Orca can auto-start Xvfb; otherwise run Xvfb in tmux and set `DISPLAY`.
- Ready output includes `pairing.url` / `Pairing URL: orca://pair?code=...`. Treat that string as secret. Persist it only in a root-only file such as `/root/.config/orca/orca-relay-pairing.txt` (mode `0600`).
- Desktop GUI alternative: open Orca → Settings → Mobile (mobile QR) or Settings runtime pairing generator (runtime URL). Still rewrite/advertise the public proxy endpoint when clients are off-LAN.

**Gate A1**

```sh
ss -ltn | grep '<orca-runtime-port>'
# optional: ORCA status --json  → running/ready/reachable when CLI is available
```

### A2. Start `orca-relay-bridge` next to the runtime

Persist non-chat secrets in an env file:

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

Start the bridge (tmux example; systemd is also fine):

```sh
tmux new-session -d -s orca-relay-bridge \
  "set -a; source /root/.config/orca/orca-relay.env; set +a; \
   exec /opt/orca-relay/current/orca-relay-bridge \
     --relay-url \"\$ORCA_RELAY_URL\" \
     --runtime-url \"\$ORCA_RUNTIME_WS_URL\" \
     --server-id \"\$ORCA_RELAY_SERVER_ID\" \
     >>/tmp/orca-relay-bridge.log 2>&1"
```

**Gate A2**

```sh
pgrep -af orca-relay-bridge
# bridge should hold an established uplink to the VPS TLS port (usually :443)
ss -tnp | grep orca-relay-bridge | grep -E ':(443|8080)\b' || true
```

Close code `1013` / `local runtime unavailable` means bridge→runtime failed: fix
`ORCA_RUNTIME_WS_URL` or start `orca serve` first.

### A3. Optional local stability layer

Only after a client has paired once:

```sh
bash scripts/orca-relay-bridge-watchdog.sh --status --json
bash scripts/orca-relay-watchdog-daemon.sh start
```

This restarts local runtime/bridge only. It never restarts VPS proxies.

---

## Phase B — Personal VPS: relay (+ public proxy for Mobile/Mac/Win)

### B1. Relay service

If not already done, follow `skills/deploy-orca-relay/SKILL.md` Phase 1.

**Gate B1**

```sh
systemctl is-active orca-relay.service
curl -fsS 'http://127.0.0.1:8080/health'     # expect {"status":"ok"}
curl -fsS 'https://<your-relay-domain.example>/health'
ss -ltnp | grep 8080                         # must be 127.0.0.1, never 0.0.0.0
```

### B2. Public proxy on the VPS (recommended for Mobile / remote desktop)

Phones and remote Mac/Win desktops usually cannot run a private local proxy and
still need a stable `wss://` endpoint inside the pairing code. Run
`orca-relay-proxy` on the VPS and put it behind TLS.

Example unit shape (paths/names are operator-owned; keep secrets in env files):

```sh
# /etc/orca-relay/orca-relay-proxy-mobile.env  (mode 0600)
ORCA_RELAY_URL=wss://127.0.0.1:8080/ws
# If the proxy is on the same host as the relay and talks over loopback plain WS:
# ORCA_RELAY_URL=ws://127.0.0.1:8080/ws
ORCA_RELAY_SERVER_ID=<server-id>
ORCA_RELAY_CLIENT_ID=mobile-public
ORCA_RELAY_BIND=127.0.0.1:17778
ORCA_RELAY_TOKEN=<relay-token-from-secure-env>
```

```sh
/opt/orca-relay/current/orca-relay-proxy \
  --bind '127.0.0.1:17778' \
  --relay-url "$ORCA_RELAY_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID" \
  --client-id "$ORCA_RELAY_CLIENT_ID"
```

Caddy (or Nginx) should terminate TLS for `<your-public-proxy-domain.example>` and
reverse-proxy to `127.0.0.1:17778`. The public client endpoint becomes:

```text
wss://<your-public-proxy-domain.example>/ws
```

That exact URL is what belongs in:

- `orca serve --pairing-address 'wss://<your-public-proxy-domain.example>/ws'`
- or `orca-relay rewrite-pairing-code --endpoint 'wss://<your-public-proxy-domain.example>/ws' ...`

**Gate B2**

```sh
curl -fsS 'https://<your-public-proxy-domain.example>/health'  # only if you expose /health there
# WebSocket upgrade smoke (expect HTTP/1.1 101 when path is correct):
curl --http1.1 -s -D- -o /dev/null --max-time 4 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  'https://<your-public-proxy-domain.example>/ws' || true
```

You may reuse the same hostname for relay and public proxy only if reverse-proxy
routing is intentional and tested. When unsure, use two hostnames.

### B3. Same shared token and serverId

| Process | Needs |
| --- | --- |
| `orca-relay` | `ORCA_RELAY_TOKEN` |
| every `orca-relay-proxy` | same token + same `serverId` + unique `clientId` |
| `orca-relay-bridge` | same token + same `serverId` + runtime URL |

Mismatch symptoms:

- `401` → token mismatch
- `503` / server absent → bridge down or `serverId` mismatch

---

## Phase C — Produce pairing codes (do not hand raw secrets to chat)

### C1. Generate on the runtime host

Prefer letting Orca mint the code, then rewrite only if the advertised endpoint is wrong.

```sh
# Capture ready JSON privately (operator machine), do not paste into agent chat.
orca serve --port <orca-runtime-port> \
  --pairing-address 'wss://<your-public-proxy-domain.example>/ws' \
  --json
# → pairing.url  (scope defaults to runtime)

orca serve --port <orca-runtime-port> \
  --pairing-address 'wss://<your-public-proxy-domain.example>/ws' \
  --mobile-pairing \
  --json
# → mobile-scoped pairing.url
```

If the minted endpoint still points at loopback/LAN, rewrite:

```sh
orca-relay rewrite-pairing-code \
  --endpoint 'wss://<your-public-proxy-domain.example>/ws' \
  '<pairing-code-or-link>'
```

For a **local-proxy CLI** path instead:

```sh
orca-relay rewrite-pairing-code \
  --endpoint 'ws://127.0.0.1:17777/ws' \
  '<pairing-code-or-link>'
```

Accepted inputs: bare URL-safe base64 payload, `orca://pair?...`, or desktop browser URL with `#pairing=`.

**Gate C1** (operator-side checks, redacted):

- rewritten offer still parses
- `endpoint` equals the intended proxy URL
- `deviceToken` / `publicKeyB64` unchanged
- `scope` is `runtime` for desktop or `mobile` for the phone app

### C2. Deliver codes to humans safely

- Prefer operator-local files, password managers, or QR shown on a private screen.
- Agent messages should say “pairing file updated on host path …” rather than dump the code.
- Rotate by minting a new offer on the runtime if a code may have leaked.

---

## Phase D — Client usage by platform

### D1. Mobile (iOS / Android)

1. Install Orca mobile (App Store / TestFlight / Android APK as the operator already uses).
2. Ensure Phase A+B are green and a **mobile-scoped** pairing code exists whose `endpoint` is the **public proxy** `wss://.../ws`.
3. In the app: scan the QR **or** paste the `orca://pair?code=...` / bare code.
4. Confirm the host entry’s endpoint is the public `wss://` proxy, not `ws://127.0.0.1:6768`.
5. Open a worktree/session and send a trivial follow-up to prove the RPC path.

LAN-only mobile debugging (no VPS) is different: same Wi-Fi, `ws://<desktop-lan-ip>:6768`, Android emulator often `ws://10.0.2.2:6768`. That path does **not** exercise orca-relay.

**Gate D1:** phone lists the host as connected and can read live terminal output.

### D2. macOS desktop Orca

1. Install/open Orca desktop on the Mac.
2. Use a **runtime-scoped** pairing URL.
3. If the Mac is off-LAN relative to the runtime host:
   - **Preferred:** pairing `endpoint` = public proxy `wss://<your-public-proxy-domain.example>/ws`
   - **Alt:** run local `orca-relay-proxy` on the Mac and rewrite endpoint to `ws://127.0.0.1:17777/ws`
4. Paste the pairing URL into the Orca client connect/pair UI (Settings runtime pairing / connect flow as shown by that build).
5. Verify worktrees/terminals from the remote runtime appear.

Local proxy on Mac (alt path):

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='<server-id>'
export ORCA_RELAY_CLIENT_ID='mac-desktop-1'
export ORCA_RELAY_BIND='127.0.0.1:17777'
export ORCA_RELAY_TOKEN='<relay-token-from-secure-env>'

orca-relay-proxy \
  --bind "$ORCA_RELAY_BIND" \
  --relay-url "$ORCA_RELAY_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID" \
  --client-id "$ORCA_RELAY_CLIENT_ID"
```

### D3. Windows desktop Orca

Same contract as macOS:

1. Runtime-scoped pairing code.
2. Public proxy endpoint **or** local Windows `orca-relay-proxy` bound to `127.0.0.1:17777`.
3. Paste pairing URL into Orca Windows client.
4. Keep `ORCA_RELAY_TOKEN` in user env / private env file; never as a CLI flag.

If only a Linux musl release binary is published, build `orca-relay-proxy` from source on Windows or run the proxy on WSL and point the rewritten endpoint at that WSL localhost forward. Do not invent a fake download URL.

### D4. Remote Orca CLI (any OS shell that uses pairing/runtime WS)

```sh
# 1) local proxy on the CLI machine
orca-relay-proxy --bind '127.0.0.1:17777' \
  --relay-url 'wss://<your-relay-domain.example>/ws' \
  --server-id '<server-id>' \
  --client-id '<client-id>'

# 2) rewrite pairing endpoint to the local proxy
orca-relay rewrite-pairing-code \
  --endpoint 'ws://127.0.0.1:17777/ws' \
  '<pairing-code-or-link>'

# 3) feed the rewritten code to the Orca client/CLI pairing flow the operator uses
```

**Gate D4:** one real CLI round trip (status / worktree list / terminal read), not only `/health`.

---

## Phase E — Agent checklist (copy into the session plan)

Work top-down. Stop at the first failed gate.

- [ ] **Runtime listening** on `<orca-runtime-port>`
- [ ] **Bridge connected** to VPS with matching `serverId` + token
- [ ] **VPS relay** loopback `/health` OK and public `https://.../health` OK
- [ ] **Public proxy** (if Mobile/Mac/Win remote) listening on loopback and TLS path upgrades WebSocket
- [ ] **Pairing offer** has correct `scope` and `endpoint`
- [ ] **Client paired** without pasting secrets into chat
- [ ] **One real session action** succeeded (mobile follow-up, desktop terminal, or CLI JSON call)
- [ ] Optional: watchdog daemon on runtime host

Report exactly which gates ran and what they proved. Green `/health` alone never proves a paired Orca session.

---

## Failure → fix (client-focused)

| Symptom | Likely layer | Fix |
| --- | --- | --- |
| Mobile scans QR but cannot connect | Pairing endpoint / public proxy | Endpoint must be public `wss://.../ws` reachable from the phone network |
| Desktop pairs then idles | Bridge or runtime | Bridge log + `ss` on runtime port; check close `1013` |
| CLI gets 503 through proxy | No bridge for `serverId` | Start bridge; align `ORCA_RELAY_SERVER_ID` |
| CLI gets 401 | Token | Same `ORCA_RELAY_TOKEN` on relay, proxy, bridge |
| Pairing rewrite fails | Payload shape | Need version `2` offer with `endpoint`, `deviceToken`, `publicKeyB64` |
| Phone works on LAN, fails on cellular | Still advertising LAN IP | Re-mint with public proxy endpoint |
| Processes healthy, clients hang | Soft death | `scripts/orca-relay-soft-death-probe.sh --once --json` |
| Agent prints secrets | Process error | Redact; rotate token and re-mint pairing offers |

---

## Rules you must not break

- Do not claim multi-tenant auth, per-client tokens, token expiry, mTLS, payload encryption, or Orca RPC inspection.
- Do not pass relay tokens as CLI flags.
- Do not commit env files that contain real tokens or pairing URLs.
- Do not tell users to modify the Orca app bundle; orca-relay is an external adapter.
- Keep the Rust relay on loopback; only TLS reverse proxies face the internet.
- When both this skill and `deploy-orca-relay` apply, install/verify the VPS first, then runtime/bridge, then clients.

## Related files

| Path | Use |
| --- | --- |
| `skills/deploy-orca-relay/SKILL.md` | VPS install + first bridge/proxy bring-up |
| `docs` in `/workspace/orca-repo/docs/reference/headless-linux-server.md` | Official `orca serve` headless behavior |
| `scripts/restart-orca-relay-mobile.sh` | Operator full restart of remote proxies + local runtime (machine-specific overrides) |
| `scripts/orca-relay-bridge-watchdog.sh` | Local auto-repair only |
| `README.md` / `README.zh-CN.md` | Human-facing overview |

## Minimal prompt an operator can paste to an agent

```text
Read skills/configure-orca-relay-clients/SKILL.md and skills/deploy-orca-relay/SKILL.md.
Configure my path: development host Orca server + orca-relay-bridge → personal VPS orca-relay
→ Win/Mac/Mobile clients via pairing codes.
Facts: VPS ssh=<vps-host>, domain=<your-relay-domain.example>, runtime host=<runtime-host>,
runtime port=<orca-runtime-port>, clients=<mobile|mac|win|cli>.
Interview me for anything missing. Never print ORCA_RELAY_TOKEN or full pairing codes.
Stop at every gate and show redacted evidence.
```
