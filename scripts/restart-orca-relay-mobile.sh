#!/usr/bin/env bash
# Restart the relay-backed headless Orca runtime and its public mobile path.
#
# Usage:
#   bash scripts/restart-orca-relay-mobile.sh
#
# Override machine-specific defaults with the ORCA_* variables shown by --help.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

REMOTE_HOST="${ORCA_RESTART_REMOTE_HOST:-ali}"
RELAY_ENV="${ORCA_RELAY_ENV_FILE:-/root/.config/orca/orca-relay.env}"
USER_DATA_PATH="${ORCA_USER_DATA_PATH:-/root/.config/orca-dev}"
BRIDGE_PATH="${ORCA_RELAY_BRIDGE_PATH:-$REPO_ROOT/target/release/orca-relay-bridge}"
MOBILE_PAIRING_ADDRESS="${ORCA_MOBILE_PAIRING_ADDRESS:-wss://<your-mobile-domain.example>/ws}"
DESKTOP_PAIRING_ADDRESS="${ORCA_DESKTOP_PAIRING_ADDRESS:-$MOBILE_PAIRING_ADDRESS}"
DESKTOP_PAIRING_FILE="${ORCA_DESKTOP_PAIRING_FILE:-/root/.config/orca/orca-relay-pairing.txt}"
LEGACY_DESKTOP_PAIRING_FILE="${ORCA_LEGACY_DESKTOP_PAIRING_FILE:-/tmp/orca-relay-pairing.txt}"
MOBILE_CHECK_URL="${MOBILE_PAIRING_ADDRESS/#wss:/https:}"
MOBILE_CHECK_URL="${MOBILE_CHECK_URL/#ws:/http:}"
RELAY_HEALTH_URL="${ORCA_RELAY_HEALTH_URL:-https://<your-relay-domain.example>/health}"
HTTP_PROXY_URL="${ORCA_RESTART_HTTP_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
ORCA_STATUS_BIN="${ORCA_STATUS_BIN:-/usr/local/bin/orca-dev}"
RUNTIME_SESSION="${ORCA_RUNTIME_TMUX_SESSION:-orca-server-relay}"
XVFB_SESSION="${ORCA_XVFB_TMUX_SESSION:-orca-xvfb}"
DISPLAY_NUMBER="${ORCA_XVFB_DISPLAY:-:99}"
RUNTIME_PORT="${ORCA_RUNTIME_PORT:-6768}"
LOG_PATH="${ORCA_RESTART_LOG_PATH:-/tmp/orca-serve-relay.log}"
START_TIMEOUT="${ORCA_RESTART_TIMEOUT_SECONDS:-30}"
MOBILE_HEADERS=""

usage() {
  cat <<'EOF'
Restart the remote Orca relay/mobile proxies and the local relay-backed runtime.

Usage:
  bash scripts/restart-orca-relay-mobile.sh

Useful overrides:
  ORCA_RESTART_REMOTE_HOST       SSH host for the VPS (default: ali)
  ORCA_RELAY_ENV_FILE            Existing relay identity env file
  ORCA_APP_ROOT                  Orca checkout containing Electron dependencies
  ORCA_RELAY_BRIDGE_PATH         orca-relay-bridge executable
  ORCA_MOBILE_PAIRING_ADDRESS    Public mobile WSS endpoint
  ORCA_DESKTOP_PAIRING_ADDRESS   Public Desktop WSS endpoint
  ORCA_DESKTOP_PAIRING_FILE      Persistent Desktop pairing-code file
  ORCA_RELAY_HEALTH_URL          Public relay health endpoint
  ORCA_RESTART_HTTP_PROXY        Proxy for public health checks; empty disables it
  ORCA_RESTART_TIMEOUT_SECONDS   Local readiness timeout (default: 30)
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 0 ]]; then
  printf 'Unknown argument: %s\n' "$1" >&2
  usage >&2
  exit 2
fi

cleanup() {
  if [[ -n "$MOBILE_HEADERS" ]]; then
    rm -f -- "$MOBILE_HEADERS"
  fi
}
trap cleanup EXIT

log() {
  printf '[orca-restart] %s\n' "$*"
}

fail() {
  printf '[orca-restart] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

resolve_app_root() {
  local candidate
  for candidate in "${ORCA_APP_ROOT:-}" "$REPO_ROOT" /workspace/orca-repo; do
    [[ -n "$candidate" && -f "$candidate/package.json" ]] || continue
    if find "$candidate/node_modules/.pnpm" -path '*/node_modules/electron/dist/electron' \
      -type f -perm -111 -print -quit 2>/dev/null | grep -q .; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_electron() {
  find "$1/node_modules/.pnpm" -path '*/node_modules/electron/dist/electron' \
    -type f -perm -111 -print -quit 2>/dev/null
}

wait_for_local_ready() {
  local deadline status
  deadline=$((SECONDS + START_TIMEOUT))
  while ((SECONDS < deadline)); do
    status="$($ORCA_STATUS_BIN status --json 2>/dev/null || true)"
    if grep -q '"running": true' <<<"$status" \
      && grep -q '"state": "ready"' <<<"$status" \
      && grep -q '"reachable": true' <<<"$status" \
      && grep -q 'orca-relay-bridge connected' "$LOG_PATH" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_tmux_session() {
  local session="$1"
  local pane_pid
  tmux has-session -t "$session" 2>/dev/null || return 0
  pane_pid="$(tmux list-panes -t "$session" -F '#{pane_pid}' | head -n 1)"
  if [[ -n "$pane_pid" ]]; then
    kill -TERM "$pane_pid" 2>/dev/null || true
    for _ in $(seq 1 5); do
      tmux has-session -t "$session" 2>/dev/null || return 0
      sleep 1
    done
  fi
  tmux kill-session -t "$session" 2>/dev/null || true
}

update_desktop_pairing_code() {
  local source_file="$DESKTOP_PAIRING_FILE"
  if [[ ! -r "$source_file" ]]; then
    source_file="$LEGACY_DESKTOP_PAIRING_FILE"
  fi
  [[ -r "$source_file" ]] \
    || fail "Desktop relay pairing code not found: $DESKTOP_PAIRING_FILE"

  node - "$source_file" "$DESKTOP_PAIRING_FILE" "$DESKTOP_PAIRING_ADDRESS" <<'NODE'
const fs = require('node:fs')

const [sourcePath, outputPath, endpoint] = process.argv.slice(2)
const source = fs.readFileSync(sourcePath, 'utf8').trim()
const url = new URL(source)
const encoded = url.searchParams.get('code')
if (!encoded) throw new Error('pairing URL has no code parameter')

const offer = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'))
if (offer.scope !== 'runtime') throw new Error('Desktop pairing code must use runtime scope')
offer.endpoint = endpoint

const pairingUrl = `orca://pair?code=${Buffer.from(JSON.stringify(offer)).toString('base64url')}`
fs.mkdirSync(require('node:path').dirname(outputPath), { recursive: true, mode: 0o700 })
const temporaryPath = `${outputPath}.tmp-${process.pid}`
fs.writeFileSync(temporaryPath, `${pairingUrl}\n`, { mode: 0o600 })
fs.renameSync(temporaryPath, outputPath)
fs.chmodSync(outputPath, 0o600)
NODE
  if [[ "$LEGACY_DESKTOP_PAIRING_FILE" != "$DESKTOP_PAIRING_FILE" ]]; then
    install -m 600 "$DESKTOP_PAIRING_FILE" "$LEGACY_DESKTOP_PAIRING_FILE"
  fi
}

require_command ssh
require_command tmux
require_command curl
require_command find
require_command install
require_command node
require_command ss
[[ -x /usr/bin/Xvfb ]] || fail "Xvfb is not executable: /usr/bin/Xvfb"
[[ -r "$RELAY_ENV" ]] || fail "relay identity file is not readable: $RELAY_ENV"
[[ -d "$USER_DATA_PATH" ]] || fail "Orca user-data directory does not exist: $USER_DATA_PATH"
[[ -x "$BRIDGE_PATH" ]] || fail "relay bridge is not executable: $BRIDGE_PATH"
[[ -x "$ORCA_STATUS_BIN" ]] || fail "Orca status CLI is not executable: $ORCA_STATUS_BIN"

APP_ROOT="$(resolve_app_root)" || fail "could not find an Orca checkout with Electron installed"
ELECTRON_BIN="${ORCA_ELECTRON_BIN:-$(resolve_electron "$APP_ROOT")}"
[[ -x "$ELECTRON_BIN" ]] || fail "Electron is not executable: $ELECTRON_BIN"

set -a
# The persisted file is the source of truth so restart never rotates relay identity.
source "$RELAY_ENV"
set +a
: "${ORCA_RELAY_URL:?ORCA_RELAY_URL is missing from $RELAY_ENV}"
: "${ORCA_RELAY_SERVER_ID:?ORCA_RELAY_SERVER_ID is missing from $RELAY_ENV}"
: "${ORCA_RELAY_TOKEN:?ORCA_RELAY_TOKEN is missing from $RELAY_ENV}"

log "restarting relay services on $REMOTE_HOST"
REMOTE_SERVICES="${ORCA_RESTART_REMOTE_SERVICES:-orca-relay.service orca-relay-proxy-mobile.service orca-relay-proxy-wx29.service caddy.service}"
# shellcheck disable=SC2086
ssh -o BatchMode=yes -o ConnectTimeout=12 "$REMOTE_HOST" \
  systemctl restart $REMOTE_SERVICES
# shellcheck disable=SC2086
ssh -o BatchMode=yes -o ConnectTimeout=12 "$REMOTE_HOST" \
  systemctl is-active --quiet $REMOTE_SERVICES \
  || fail "one or more remote relay services failed to become active"

log "stopping old local tmux sessions"
stop_tmux_session "$RUNTIME_SESSION"
stop_tmux_session "$XVFB_SESSION"

for _ in $(seq 1 10); do
  if ! ss -ltn 2>/dev/null | grep -qE "[.:]${RUNTIME_PORT}[[:space:]]"; then
    break
  fi
  sleep 1
done
if ss -ltn 2>/dev/null | grep -qE "[.:]${RUNTIME_PORT}[[:space:]]"; then
  fail "port $RUNTIME_PORT is still occupied after stopping $RUNTIME_SESSION"
fi

log "starting Xvfb in tmux session $XVFB_SESSION"
tmux new-session -d -s "$XVFB_SESSION" -- \
  /usr/bin/Xvfb "$DISPLAY_NUMBER" -screen 0 1280x720x24 -nolisten tcp

display_socket="/tmp/.X11-unix/X${DISPLAY_NUMBER#:}"
for _ in $(seq 1 5); do
  [[ -S "$display_socket" ]] && break
  tmux has-session -t "$XVFB_SESSION" 2>/dev/null \
    || fail "Xvfb exited before creating $display_socket"
  sleep 1
done
[[ -S "$display_socket" ]] || fail "Xvfb did not create $display_socket"

: >"$LOG_PATH"
chmod 600 "$LOG_PATH"

printf -v launch_command \
  'set -a; source %q; set +a; exec env -u ELECTRON_RUN_AS_NODE DISPLAY=%q LIBGL_ALWAYS_SOFTWARE=1 ORCA_USER_DATA_PATH=%q %q --no-sandbox %q --serve --serve-port %q --serve-mobile-pairing --serve-pairing-address %q --serve-relay-url %q --serve-relay-server-id %q --serve-relay-bridge-path %q >>%q 2>&1' \
  "$RELAY_ENV" "$DISPLAY_NUMBER" "$USER_DATA_PATH" "$ELECTRON_BIN" "$APP_ROOT" \
  "$RUNTIME_PORT" "$MOBILE_PAIRING_ADDRESS" "$ORCA_RELAY_URL" \
  "$ORCA_RELAY_SERVER_ID" "$BRIDGE_PATH" "$LOG_PATH"

# Root-launched Electron needs --no-sandbox, and tmux prevents session teardown from reaping it.
log "starting Orca runtime in tmux session $RUNTIME_SESSION"
tmux new-session -d -s "$RUNTIME_SESSION" "$launch_command"

if ! wait_for_local_ready; then
  tail -n 80 "$LOG_PATH" >&2 || true
  fail "local runtime or relay bridge did not become ready within ${START_TIMEOUT}s"
fi

# Desktop clients use the public proxy on ali; a loopback endpoint would require a local proxy.
log "updating public Desktop relay pairing code"
update_desktop_pairing_code

if [[ -n "$HTTP_PROXY_URL" ]]; then
  export http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL"
fi

log "checking public relay health"
health="$(curl -fsS --max-time 10 "$RELAY_HEALTH_URL")" \
  || fail "public relay health check failed: $RELAY_HEALTH_URL"
grep -q '"status":"ok"' <<<"$health" \
  || fail "public relay returned an unexpected health response: $health"

log "checking public mobile WebSocket upgrade"
MOBILE_HEADERS="$(mktemp "${TMPDIR:-/tmp}/orca-mobile-ws.XXXXXXXX")"
curl --http1.1 -s -D "$MOBILE_HEADERS" -o /dev/null --max-time 4 \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: T3JjYU1vYmlsZVJlc3RhcnQ=' \
  "$MOBILE_CHECK_URL" || true
grep -qE '^HTTP/1\.1 101 ' "$MOBILE_HEADERS" \
  || fail "public mobile endpoint did not complete a WebSocket upgrade"

log "restart complete"
"$ORCA_STATUS_BIN" status --json
