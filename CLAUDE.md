# Claude Code Guide for Orca Relay

## Project Summary

- Orca Relay is a small Rust adapter layer that keeps Orca CLI usable through a VPS relay without modifying the Orca app bundle.
- Runtime path: remote Orca CLI -> `orca-relay-proxy` -> VPS `orca-relay` `/ws` -> `orca-relay-bridge` -> local Orca runtime WebSocket.
- The relay carries binary adapter frames and routes by `serverId` / `clientId`; Orca application payload bytes are opaque to this project.
- Do not describe Orca Relay as providing end-to-end encryption. It does not inspect, decrypt, transform, or log opaque payload bytes, but opacity is not encryption.
- `Cargo.toml` has `publish = false`; do not claim crates.io or package-manager installation.

## Architecture and Key Files

- `Cargo.toml`: crate metadata and binary targets:
  - `orca-relay` at `src/main.rs`
  - `orca-relay-proxy` at `src/bin/orca-relay-proxy.rs`
  - `orca-relay-bridge` at `src/bin/orca-relay-bridge.rs`
- `src/lib.rs`: relay Axum app, health and WebSocket handling, pairing-code rewrite logic, adapter frame codec, proxy runtime, and bridge runtime.
- `src/main.rs`: VPS relay server entrypoint plus `rewrite-pairing-code` subcommand.
- `src/bin/orca-relay-proxy.rs`: remote-side local WebSocket proxy CLI.
- `src/bin/orca-relay-bridge.rs`: desktop/runtime-side bridge CLI.
- `tests/relay_contract.rs`: `/health`, bearer auth, fail-fast routing, and server/client replacement behavior.
- `tests/adapter_contract.rs`: adapter frame codec and proxy/bridge round trips without mutating bytes.
- `tests/pairing_code.rs`: endpoint-only pairing-code rewrites and invalid-input rejection.
- `scripts/`: VPS installer, systemd/Caddy/env templates, latency helpers, soft-death probe, local watchdog, detached watchdog supervisor, full restart helper, and script safety checks.
- `skills/deploy-orca-relay/SKILL.md`: agent-executable deployment runbook for VPS operators with or without their own domain.
- `skills/configure-orca-relay-clients/SKILL.md`: agent runbook for development-host `orca serve` + bridge, personal VPS, and Win/Mac/Mobile pairing-code clients.
- `assets/README.md` and `assets/prompts/`: public-safe image-generation prompts and expected image paths.

## Claude Development Workflow

- For multi-file changes, first map the affected files, then use subagents/worktrees for independent slices. Keep one agent from editing the same file as another unless coordinated.
- Preserve existing conventions: Rust async code uses Tokio/Axum/Tungstenite; tests are contract-style and prefer real local WebSocket components over mocks.
- Before changing exported symbols or shared behavior, find all call sites and update the relevant contract tests.
- Keep changes focused. Do not add auth systems, connection pooling, account models, rate limiting, audit logs, encryption layers, or persistent helpers unless explicitly requested.
- Verify before completion with the narrowest command that proves the change, unless the user explicitly forbids running commands.
- Never commit generated junk: `target/`, `__pycache__/`, filled env files, local logs, latency output, real pairing material, or rendered secrets.

## Commands

Use these as references for future Claude sessions; choose the smallest sufficient verification for the change.

- Build release binaries:

```sh
cargo build --release
```

- Run Rust contract tests:

```sh
cargo test
```

- Formatting and Clippy checks:

```sh
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
```

- Support-script checks:

```sh
python3 scripts/test_support_scripts.py
python3 -m py_compile scripts/measure-relay-ws-latency.py scripts/test_support_scripts.py
bash -n scripts/cloudflare-relay-mode.sh scripts/compare-cloudflare-relay-latency.sh scripts/install-vps.sh scripts/orca-relay-bridge-watchdog.sh scripts/orca-relay-soft-death-probe.sh scripts/orca-relay-watchdog-daemon.sh scripts/restart-orca-relay-mobile.sh
```

- Full contributor release gate from `README.md`:

```sh
cargo test && cargo fmt --check && cargo clippy --all-targets --all-features -- -D warnings && python3 scripts/test_support_scripts.py && python3 -m py_compile scripts/measure-relay-ws-latency.py scripts/test_support_scripts.py && bash -n scripts/cloudflare-relay-mode.sh scripts/compare-cloudflare-relay-latency.sh scripts/install-vps.sh scripts/orca-relay-bridge-watchdog.sh scripts/orca-relay-soft-death-probe.sh scripts/orca-relay-watchdog-daemon.sh scripts/restart-orca-relay-mobile.sh
```

## Release Maintenance

- For v0.1.0, GitHub release assets are precompiled tarballs named `orca-relay-v0.1.0-<target>.tar.gz`.
- Each tarball must contain exactly the three release binaries: `orca-relay`, `orca-relay-proxy`, and `orca-relay-bridge`.
- After `cargo build --release`, use `scripts/package-release.sh` to package built binaries and checksums for upload.
- Installer flows should download GitHub release assets by tag; verify checksums before use and never upload `target/`, secrets, tokens, pairing material, or filled env files.

## Usage Examples

Use placeholders only. Do not paste real relay tokens, pairing codes, `deviceToken`, `publicKeyB64`, Cloudflare credentials, VPS IPs, or private endpoints into prompts, commits, logs, issues, or screenshots.

### VPS relay server

```sh
export ORCA_RELAY_BIND='127.0.0.1:8080'
export ORCA_RELAY_TOKEN='<your-relay-token>'

orca-relay
# or with a non-secret bind flag:
orca-relay --bind "$ORCA_RELAY_BIND"
```

The server exposes unauthenticated `GET /health` and authenticated `GET /ws` behind a TLS reverse proxy.

### Desktop/runtime-side bridge

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='desktop-orca'
export ORCA_RUNTIME_WS_URL='ws://127.0.0.1:<orca-runtime-port>/ws'
export ORCA_RELAY_TOKEN='<your-relay-token>'

orca-relay-bridge
```

Equivalent with non-secret flags:

```sh
orca-relay-bridge \
  --relay-url "$ORCA_RELAY_URL" \
  --runtime-url "$ORCA_RUNTIME_WS_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID"
```

### Remote CLI-side proxy

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='desktop-orca'
export ORCA_RELAY_CLIENT_ID='remote-cli-1'
export ORCA_RELAY_BIND='127.0.0.1:17777'
export ORCA_RELAY_TOKEN='<your-relay-token>'

orca-relay-proxy
```

Equivalent with non-secret flags:

```sh
orca-relay-proxy \
  --bind "$ORCA_RELAY_BIND" \
  --relay-url "$ORCA_RELAY_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID" \
  --client-id "$ORCA_RELAY_CLIENT_ID"
```

Use the printed local endpoint, normally `ws://127.0.0.1:17777/ws`, as the pairing-code endpoint.

### Pairing-code endpoint rewrite

```sh
orca-relay rewrite-pairing-code \
  --endpoint 'ws://127.0.0.1:17777/ws' \
  '<pairing-code-or-link>'
```

The helper rewrites only the endpoint, preserves `deviceToken` and `publicKeyB64`, and validates pairing payload version `2`.

## Release Maintenance

- For v0.1.0, GitHub release assets are precompiled tarballs named `orca-relay-v0.1.0-<target>.tar.gz`.
- Each tarball should contain `orca-relay`, `orca-relay-proxy`, and `orca-relay-bridge`; `scripts/package-release.sh` also includes the English and Chinese README files for convenience.
- Build release binaries with an explicit target such as `cargo build --release --target x86_64-unknown-linux-musl --bins`, then run `scripts/package-release.sh v0.1.0 x86_64-unknown-linux-musl` to create the tarball and checksum.
- The VPS installer downloads GitHub release assets by tag. Verify checksums before use and never upload `target/`, secrets, tokens, pairing material, or filled env files.

## Deployment and Secret Handling

- `ORCA_RELAY_TOKEN` is environment-only. Never document or add a token CLI flag.
- The relay, proxy, bridge, installer, and latency helper must read tokens from `ORCA_RELAY_TOKEN` or, for the installer, `ORCA_RELAY_TOKEN_FILE`.
- `serverId` and `clientId` are routing identifiers, not secrets.
- Public relay traffic should use `wss://` through Caddy/Nginx or another TLS reverse proxy. Keep the Rust relay bound to loopback.
- Deployment templates:
  - `scripts/orca-relay.env.example`: copy outside the repo and fill secrets there.
  - `scripts/orca-relay.service.template`: systemd unit for `/opt/orca-relay/orca-relay` with `/etc/orca-relay/orca-relay.env`.
  - `scripts/Caddyfile.orca-relay.template`: reverse proxy to `127.0.0.1:8080`.
- `scripts/install-vps.sh` supports `install`, `render`, `rollback`, and `uninstall`; render/dry-run output must redact tokens.
- Do not include real domains, IPs, tokens, pairing links, raw pairing payloads, Cloudflare credentials, or private service URLs in public docs or committed examples.

## Image and Documentation Maintenance

- Keep `README.md`, public examples, and generated diagrams consistent with the real CLI flags and environment variables.
- Use `assets/prompts/` as the source of truth for image-generation copy.
- Do not create fake, blank, or placeholder PNG files. Add images only after real generation and review.
- Image text must stay public-safe: no real tokens, hostnames, IPs, pairing codes, credentials, QR codes, private URLs, or personal identifiers.
- Preserve the exact security boundary in docs and diagrams: payload bytes are opaque; Orca Relay is not an encryption layer.
- Keep README examples placeholder-based and avoid referencing any live development relay as a shared public service contract.
