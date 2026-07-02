# Agent Instructions for Orca Relay

## Project summary

- Orca Relay is a small Rust adapter layer that keeps Orca CLI usable through a VPS relay without modifying the Orca app bundle.
- Runtime flow: `Orca CLI -> orca-relay-proxy -> VPS orca-relay /ws -> orca-relay-bridge -> local Orca runtime`.
- The relay carries opaque WebSocket payload bytes inside adapter frames. It does not patch Orca, parse Orca RPCs, inspect application payloads, regenerate credentials, or provide an encryption layer.
- The crate is private to this repository: `Cargo.toml` has `publish = false`; do not describe a crates.io or package-manager install path.

## Architecture and important binaries

- `src/lib.rs`: relay router, health endpoint, pairing-code rewrite logic, adapter frame codec, proxy/bridge runtime implementation.
- `src/main.rs`: `orca-relay` VPS server and `rewrite-pairing-code` subcommand.
- `src/bin/orca-relay-proxy.rs`: remote-side local WebSocket proxy for the machine running Orca CLI.
- `src/bin/orca-relay-bridge.rs`: desktop/runtime-side bridge that can reach the real Orca runtime WebSocket.
- `tests/relay_contract.rs`: relay auth, health, routing, and replacement socket behavior.
- `tests/adapter_contract.rs`: adapter frame codec plus proxy/bridge forwarding behavior.
- `tests/pairing_code.rs`: pairing-code input shapes and endpoint-only rewrite behavior.
- `scripts/install-vps.sh`: systemd/Caddy VPS installer; token input is environment or token file only.
- `scripts/orca-relay.env.example`, `scripts/orca-relay.service.template`, `scripts/Caddyfile.orca-relay.template`: deployment templates.
- `scripts/measure-relay-ws-latency.py`, `scripts/cloudflare-relay-mode.sh`, `scripts/compare-cloudflare-relay-latency.sh`, `scripts/test_support_scripts.py`: operations and support checks.

## Safe development rules

- Inspect existing README, source, scripts, and tests before changing behavior. Keep changes narrow and aligned with current contracts.
- Do not invent capabilities. In particular, do not claim multi-tenant authorization, per-client tokens, token expiry, token hashing, mTLS, Origin allow-listing, rate limiting, audit logs, persistent helpers, connection pooling, payload encryption, or Orca RPC inspection unless the code actually implements it.
- `ORCA_RELAY_TOKEN` is environment-only. Never add or document a relay-token CLI flag for the server, proxy, bridge, or installer.
- Never commit, log, print, or paste real relay tokens, `Authorization` headers, pairing codes, `deviceToken`, `publicKeyB64`, Cloudflare credentials, VPS IPs, private endpoints, or raw production URLs.
- Use placeholders such as `<your-relay-domain.example>`, `<relay-token-from-secure-env>`, `<server-id>`, `<client-id>`, `<orca-runtime-port>`, and `<pairing-code-or-link>` in docs and examples.
- Treat adapter payload bytes as opaque. It is correct to say Orca Relay does not inspect or transform them; it is not correct to call that end-to-end encryption.
- Pairing-code rewrite must only change the endpoint and preserve existing sensitive pairing fields.
- For public deployments, keep the Rust relay bound to loopback and expose it through TLS reverse proxy infrastructure such as Caddy/Nginx.

## Build, test, and verification commands

Use focused checks for touched areas before claiming work is done. Common commands:

```sh
cargo build --release
cargo test
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
python3 scripts/test_support_scripts.py
python3 -m py_compile scripts/measure-relay-ws-latency.py scripts/test_support_scripts.py
bash -n scripts/cloudflare-relay-mode.sh scripts/compare-cloudflare-relay-latency.sh scripts/install-vps.sh
```

Contributor release gate from the README:

```sh
cargo test && cargo fmt --check && cargo clippy --all-targets --all-features -- -D warnings && python3 scripts/test_support_scripts.py && python3 -m py_compile scripts/measure-relay-ws-latency.py scripts/test_support_scripts.py && bash -n scripts/cloudflare-relay-mode.sh scripts/compare-cloudflare-relay-latency.sh scripts/install-vps.sh
```

Health checks after deployment:

```sh
curl -fsS 'https://<your-relay-domain.example>/health'
curl -fsS 'http://127.0.0.1:8080/health'
```

These checks do not prove that a live Orca Desktop/CLI session, DNS, Cloudflare, TLS, or latency target was exercised.

## Running the components with placeholders

### VPS relay server

```sh
export ORCA_RELAY_BIND='127.0.0.1:8080'
export ORCA_RELAY_TOKEN='<relay-token-from-secure-env>'

cargo run --bin orca-relay -- --bind "$ORCA_RELAY_BIND"
```

Production deployments normally run the release binary under systemd using `/etc/orca-relay/orca-relay.env`, with the public `wss://` endpoint provided by a TLS reverse proxy.

### Desktop/runtime-side bridge

Run near the real Orca runtime:

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='<server-id>'
export ORCA_RUNTIME_WS_URL='ws://127.0.0.1:<orca-runtime-port>/ws'
export ORCA_RELAY_TOKEN='<relay-token-from-secure-env>'

cargo run --bin orca-relay-bridge -- \
  --relay-url "$ORCA_RELAY_URL" \
  --runtime-url "$ORCA_RUNTIME_WS_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID"
```

### Remote CLI-side proxy

Run on the machine where Orca CLI runs:

```sh
export ORCA_RELAY_URL='wss://<your-relay-domain.example>/ws'
export ORCA_RELAY_SERVER_ID='<server-id>'
export ORCA_RELAY_CLIENT_ID='<client-id>'
export ORCA_RELAY_BIND='127.0.0.1:17777'
export ORCA_RELAY_TOKEN='<relay-token-from-secure-env>'

cargo run --bin orca-relay-proxy -- \
  --bind "$ORCA_RELAY_BIND" \
  --relay-url "$ORCA_RELAY_URL" \
  --server-id "$ORCA_RELAY_SERVER_ID" \
  --client-id "$ORCA_RELAY_CLIENT_ID"
```

Use the local proxy endpoint, normally `ws://127.0.0.1:17777/ws`, as the pairing-code endpoint.

### Pairing-code endpoint rewrite

```sh
cargo run --bin orca-relay -- rewrite-pairing-code \
  --endpoint 'ws://127.0.0.1:17777/ws' \
  '<pairing-code-or-link>'
```

Supported input shapes are bare URL-safe base64 pairing payloads, `orca://pair?...` links, and Orca Desktop browser URLs containing `#pairing=`.

## Deployment and secrets

- Installer usage should pin a release tag and inspect the script when an auditable path is needed.
- Do not pass tokens as flags. The installer accepts token material only via `ORCA_RELAY_TOKEN` or `ORCA_RELAY_TOKEN_FILE`; render/dry-run output should redact secrets.
- Manual VPS layout is documented in the README: release files under `/opt/orca-relay/`, env under `/etc/orca-relay/orca-relay.env`, systemd unit under `/etc/systemd/system/`, optional Caddy site under `/etc/caddy/conf.d/`, and state/snapshots under `/var/lib/orca-relay/`.
- Cloudflare helper scripts are operational aids, not proof that DNS/TLS/WebSocket behavior is correct for a specific deployment.

## Codex workflow expectations

- Inspect first, then edit. Prefer `grep`/targeted reads over broad rewrites.
- Preserve public-safe documentation. Replace real operational values with placeholders.
- Keep patches minimal, remove obsolete code when necessary, and update tests/docs only where behavior actually changes.
- Never log or expose secrets while debugging.
- Before saying a change is done, run focused verification that covers the files or behavior you changed, and state exactly what was run and what it proves.
