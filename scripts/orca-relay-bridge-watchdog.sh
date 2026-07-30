#!/usr/bin/env bash
# Local connectivity watchdog for headless Orca serve + bridge.
#
# Policy (operator preference):
#   If the path cannot connect, repair it.
#   Most real outages are the runtime itself dying — so restart the local runtime
#   (Xvfb + `orca serve`), not only the bridge.
#   The current `orca serve` CLI accepts no relay arguments and does not parent a
#   bridge, so the runtime and the bridge are supervised here as two independent
#   tmux services. Restart only the component that failed.
#   Never bounce remote / public proxy services from this script.
#
# Usage:
#   bash scripts/orca-relay-bridge-watchdog.sh            # one check/repair
#   bash scripts/orca-relay-bridge-watchdog.sh --loop      # every INTERVAL s
#   bash scripts/orca-relay-bridge-watchdog.sh --status    # print status only
#   bash scripts/orca-relay-bridge-watchdog.sh --once --json
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RELAY_ENV="${ORCA_RELAY_ENV_FILE:-/root/.config/orca/orca-relay.env}"
BRIDGE_PATH="${ORCA_RELAY_BRIDGE_PATH:-$REPO_ROOT/target/release/orca-relay-bridge}"
CLI_BIN="${ORCA_CLI_BIN:-orca}"
APP_ROOT="${ORCA_APP_ROOT:-/workspace/orca-repo}"
USER_DATA_PATH="${ORCA_USER_DATA_PATH:-/root/.config/orca-dev}"
RUNTIME_URL="${ORCA_RUNTIME_WS_URL:-ws://127.0.0.1:6768/}"
RUNTIME_PORT="${ORCA_RUNTIME_PORT:-6768}"
RUNTIME_SESSION="${ORCA_RUNTIME_TMUX_SESSION:-orca-server-relay}"
BRIDGE_SESSION="${ORCA_BRIDGE_TMUX_SESSION:-orca-relay-bridge}"
XVFB_SESSION="${ORCA_XVFB_TMUX_SESSION:-orca-xvfb}"
DISPLAY_NUMBER="${ORCA_XVFB_DISPLAY:-:99}"
MOBILE_PAIRING_ADDRESS="${ORCA_MOBILE_PAIRING_ADDRESS:-wss://<your-mobile-domain.example>/ws}"
SERVE_LOG_PATH="${ORCA_RESTART_LOG_PATH:-/tmp/orca-serve-relay.log}"
RELAY_HEALTH_URL="${ORCA_RELAY_HEALTH_URL:-https://<your-relay-domain.example>/health}"
HTTP_PROXY_URL="${ORCA_WATCHDOG_HTTP_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
INTERVAL_SECONDS="${ORCA_WATCHDOG_INTERVAL_SECONDS:-15}"
LOG_PATH="${ORCA_WATCHDOG_LOG_PATH:-/tmp/orca-relay-bridge-watchdog.log}"
BRIDGE_LOG_PATH="${ORCA_WATCHDOG_BRIDGE_LOG_PATH:-/tmp/orca-relay-bridge.watchdog.log}"
XVFB_LOG_PATH="${ORCA_WATCHDOG_XVFB_LOG_PATH:-/tmp/orca-relay-xvfb.watchdog.log}"
PID_PATH="${ORCA_WATCHDOG_BRIDGE_PID_PATH:-/tmp/orca-relay-bridge.watchdog.pid}"
STATE_PATH="${ORCA_WATCHDOG_STATE_PATH:-/tmp/orca-relay-bridge-watchdog.state}"
# Soft-death thresholds: TCP can stay ESTAB while the relay session is wedged.
# High Send-Q alone is common under load; require a stall before bridge restart.
SENDQ_WARN="${ORCA_WATCHDOG_SENDQ_WARN:-65536}"
SENDQ_CRIT="${ORCA_WATCHDOG_SENDQ_CRIT:-512000}"
SENDQ_STREAK_RESTART="${ORCA_WATCHDOG_SENDQ_STREAK_RESTART:-6}"
STALL_STREAK_RESTART="${ORCA_WATCHDOG_STALL_STREAK_RESTART:-2}"
SOFT_DEATH_REPAIR="${ORCA_WATCHDOG_SOFT_DEATH_REPAIR:-1}"
# Restart full local runtime (Electron) when :6768 is down. Default ON.
RUNTIME_REPAIR="${ORCA_WATCHDOG_RUNTIME_REPAIR:-1}"
# Cooldown after a runtime restart to avoid thrash (seconds).
RUNTIME_RESTART_COOLDOWN_S="${ORCA_WATCHDOG_RUNTIME_RESTART_COOLDOWN_S:-90}"
RUNTIME_READY_TIMEOUT_S="${ORCA_WATCHDOG_RUNTIME_READY_TIMEOUT_S:-45}"
# Bridge start attempts while waiting for a restarted runtime to become ready.
BRIDGE_START_ATTEMPTS="${ORCA_WATCHDOG_BRIDGE_START_ATTEMPTS:-3}"
MODE="once"
JSON=0
PREV_SENT=0
PREV_TS=0
SENDQ_HIGH_STREAK=0
STALL_STREAK=0
LAST_RUNTIME_RESTART_TS=0

usage() {
  cat <<'EOF'
Watch/repair the local Orca runtime + bridge when connectivity is lost.

Does NOT restart remote / public proxies.

Usage:
  bash scripts/orca-relay-bridge-watchdog.sh [--once|--loop|--status] [--json]

Env overrides:
  ORCA_RELAY_ENV_FILE / ORCA_RELAY_BRIDGE_PATH / ORCA_CLI_BIN / ORCA_APP_ROOT
  ORCA_APP_EXECUTABLE                       Electron binary used by `orca serve`
  ORCA_RUNTIME_WS_URL / ORCA_RUNTIME_PORT
  ORCA_RUNTIME_TMUX_SESSION / ORCA_BRIDGE_TMUX_SESSION
  ORCA_XVFB_TMUX_SESSION / ORCA_XVFB_DISPLAY
  ORCA_MOBILE_PAIRING_ADDRESS / ORCA_USER_DATA_PATH
  ORCA_RELAY_HEALTH_URL / ORCA_WATCHDOG_HTTP_PROXY
  ORCA_WATCHDOG_INTERVAL_SECONDS
  ORCA_WATCHDOG_RUNTIME_REPAIR              0 disables runtime restart
  ORCA_WATCHDOG_RUNTIME_RESTART_COOLDOWN_S  default 90
  ORCA_WATCHDOG_BRIDGE_START_ATTEMPTS       default 3
  ORCA_WATCHDOG_XVFB_LOG_PATH               Xvfb stderr capture for diagnosis
  ORCA_WATCHDOG_SOFT_DEATH_REPAIR           0 disables bridge soft-death restart
  ORCA_WATCHDOG_SENDQ_WARN / ORCA_WATCHDOG_SENDQ_CRIT
  ORCA_WATCHDOG_SENDQ_STREAK_RESTART / ORCA_WATCHDOG_STALL_STREAK_RESTART
EOF
}

load_state() {
  [[ -r "$STATE_PATH" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_PATH" || true
}

save_state() {
  cat >"$STATE_PATH" <<EOF
PREV_SENT=${PREV_SENT}
PREV_TS=${PREV_TS}
SENDQ_HIGH_STREAK=${SENDQ_HIGH_STREAK}
STALL_STREAK=${STALL_STREAK}
LAST_RUNTIME_RESTART_TS=${LAST_RUNTIME_RESTART_TS}
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_PATH" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) MODE="once"; shift ;;
    --loop) MODE="loop"; shift ;;
    --status) MODE="status"; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -r "$RELAY_ENV" ]] || fail "relay env not readable: $RELAY_ENV"
[[ -x "$BRIDGE_PATH" ]] || fail "bridge not executable: $BRIDGE_PATH"
command -v "$CLI_BIN" >/dev/null 2>&1 || fail "Orca CLI not found: $CLI_BIN (set ORCA_CLI_BIN)"

set -a
# shellcheck disable=SC1090
source "$RELAY_ENV"
set +a
: "${ORCA_RELAY_URL:?ORCA_RELAY_URL missing from $RELAY_ENV}"
: "${ORCA_RELAY_SERVER_ID:?ORCA_RELAY_SERVER_ID missing from $RELAY_ENV}"
: "${ORCA_RELAY_TOKEN:?ORCA_RELAY_TOKEN missing from $RELAY_ENV}"

resolve_electron() {
  local candidate
  # `orca serve` needs an Electron binary. Honor an explicit operator override
  # first, then the plain checkout layout, then a pnpm store layout.
  for candidate in "${ORCA_APP_EXECUTABLE:-}" "${ORCA_ELECTRON_BIN:-}" \
    "$APP_ROOT/node_modules/electron/dist/electron"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  find "$APP_ROOT/node_modules/.pnpm" -path '*/node_modules/electron/dist/electron' \
    -type f -perm -111 -print -quit 2>/dev/null
}

runtime_port_open() {
  local line
  while read -r line; do
    # shellcheck disable=SC2086
    set -- $line
    local local_addr="$4"
    case "$local_addr" in
      *:"$RUNTIME_PORT") return 0 ;;
    esac
  done < <(ss -ltn 2>/dev/null)
  return 1
}

electron_serve_pids() {
  ps -eo pid=,args= | awk -v port="$RUNTIME_PORT" '
    /electron/ && /--serve/ && $0 ~ ("--serve-port " port) { print $1 }
  '
}

bridge_pids() {
  # Match the actual bridge binary invocation, not an Electron argument that
  # merely mentions the bridge path, and not this watchdog shell script itself.
  ps -eo pid=,args= | awk -v bridge="$BRIDGE_PATH" '
    $0 ~ bridge && /--relay-url/ && /--server-id/ && $0 !~ /electron/ && $0 !~ /watchdog/ { print $1 }
  '
}

bridge_connected_to_relay() {
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if ss -tnp 2>/dev/null | grep -E "pid=$pid," | grep -qE ':443\b'; then
      return 0
    fi
  done < <(bridge_pids)
  return 1
}

# Prints: pid sendq bytes_sent lastrcv unacked connected(0/1)
bridge_tcp_stats() {
  BRIDGE_PATH="$BRIDGE_PATH" python3 - <<'PY'
import os, re, subprocess
bridge = os.environ["BRIDGE_PATH"]
pids = []
for line in subprocess.check_output(["ps", "-eo", "pid=,args="], text=True).splitlines():
    if (
        bridge in line
        and "--relay-url" in line
        and "--server-id" in line
        and "electron" not in line
        and "watchdog" not in line
    ):
        pids.append(line.strip().split()[0])
if not pids:
    print("0 0 0 -1 0 0")
    raise SystemExit
pid = pids[0]
out = subprocess.check_output(["ss", "-Htnpi", "dst", ":443"], text=True, stderr=subprocess.DEVNULL)
lines = out.splitlines()
head = info = ""
for i, line in enumerate(lines):
    if f"pid={pid}," in line and ":443" in line:
        head = line
        for j in range(i + 1, min(i + 3, len(lines))):
            if re.search(r"bytes_sent:|rtt:", lines[j]):
                info = lines[j]
                break
        break
if not head:
    print(f"{pid} 0 0 -1 0 0")
    raise SystemExit
parts = head.split()
sendq = 0
try:
    if parts[0] in {"ESTAB", "ESTABLISHED"}:
        sendq = int(parts[2])
    else:
        sendq = int(parts[1])
except Exception:
    pass
def g(pat, default):
    m = re.search(pat, info)
    return m.group(1) if m else default
sent = g(r"bytes_sent:(\d+)", "0")
lastrcv = g(r"lastrcv:(\d+)", "-1")
unacked = g(r"unacked:(\d+)", "0")
print(pid, sendq, sent, lastrcv, unacked, 1)
PY
}

public_health_ok() {
  local args=( -fsS --max-time 8 )
  if [[ -n "$HTTP_PROXY_URL" ]]; then
    args+=( -x "$HTTP_PROXY_URL" )
  fi
  local body
  body="$(curl "${args[@]}" "$RELAY_HEALTH_URL" 2>/dev/null || true)"
  grep -q '"status":"ok"' <<<"$body"
}

stop_tmux_session() {
  local session="$1"
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session" 2>/dev/null || true
  fi
}

ensure_xvfb() {
  local display_socket="/tmp/.X11-unix/X${DISPLAY_NUMBER#:}"
  local launch_command
  if tmux has-session -t "$XVFB_SESSION" 2>/dev/null && [[ -S "$display_socket" ]]; then
    return 0
  fi
  stop_tmux_session "$XVFB_SESSION"
  : >"$XVFB_LOG_PATH"
  chmod 600 "$XVFB_LOG_PATH" 2>/dev/null || true
  log "starting Xvfb in tmux session $XVFB_SESSION ($DISPLAY_NUMBER)"
  printf -v launch_command \
    'exec /usr/bin/Xvfb %q -screen 0 1280x720x24 -nolisten tcp >>%q 2>&1' \
    "$DISPLAY_NUMBER" "$XVFB_LOG_PATH"
  tmux new-session -d -s "$XVFB_SESSION" "$launch_command"
  for _ in $(seq 1 8); do
    # A socket alone is not proof of a live server: a stale socket and lock file
    # outlive a crashed Xvfb, and the replacement then refuses to start. Require
    # the Xvfb we just launched to still be running.
    if tmux has-session -t "$XVFB_SESSION" 2>/dev/null && [[ -S "$display_socket" ]]; then
      return 0
    fi
    tmux has-session -t "$XVFB_SESSION" 2>/dev/null || break
    sleep 1
  done
  log "ERROR: Xvfb did not stay up on $DISPLAY_NUMBER (socket=$display_socket)"
  tail -n 20 "$XVFB_LOG_PATH" 2>/dev/null | while read -r line; do
    log "xvfb-log: $line"
  done || true
  return 1
}

kill_stale_runtime() {
  # Prefer graceful Electron quit so headless serve can:
  #   1) capture sleeping-agent resume records
  #   2) disconnectDaemon() without killing detached PTY sessions
  # Only escalate to KILL if the process ignores SIGTERM.
  local pid i
  local had_electron=0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    had_electron=1
    log "sending SIGTERM to Electron serve pid=$pid (graceful quit for agent resume/daemon)"
    kill -TERM "$pid" 2>/dev/null || true
  done < <(electron_serve_pids)

  if [[ "$had_electron" -eq 1 ]]; then
    for i in $(seq 1 20); do
      if [[ -z "$(electron_serve_pids)" ]] && ! runtime_port_open; then
        break
      fi
      sleep 1
    done
  fi

  # The bridge is an independent service; stop it alongside the runtime so the
  # pair restarts together instead of pointing at a dead runtime socket.
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < <(bridge_pids)
  sleep 2

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    log "force-killing stubborn Electron pid=$pid"
    kill -KILL "$pid" 2>/dev/null || true
  done < <(electron_serve_pids)
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done < <(bridge_pids)

  stop_tmux_session "$BRIDGE_SESSION"
  stop_tmux_session "$RUNTIME_SESSION"

  for i in $(seq 1 10); do
    runtime_port_open || return 0
    sleep 1
  done
  if runtime_port_open; then
    log "WARNING: port $RUNTIME_PORT still listening after kill attempts"
    return 1
  fi
  return 0
}

wait_for_local_ready() {
  local bridge_attempts=0
  for _ in $(seq 1 "$RUNTIME_READY_TIMEOUT_S"); do
    if runtime_port_open; then
      # Nothing else spawns the bridge for us, so start it here once the runtime
      # socket is listening. Bounded attempts keep a broken bridge from looping.
      if [[ -z "$(bridge_pids)" && "$bridge_attempts" -lt "$BRIDGE_START_ATTEMPTS" ]]; then
        bridge_attempts=$((bridge_attempts + 1))
        start_bridge || true
      fi
      if [[ -n "$(bridge_pids)" ]] && bridge_connected_to_relay; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

restart_local_runtime() {
  local reason="$1"
  local now electron_bin launch_command
  now="$(date +%s)"
  load_state
  if [[ "${LAST_RUNTIME_RESTART_TS:-0}" -gt 0 ]]; then
    local elapsed=$((now - LAST_RUNTIME_RESTART_TS))
    if [[ "$elapsed" -lt "$RUNTIME_RESTART_COOLDOWN_S" ]]; then
      log "runtime down ($reason) but cooldown ${elapsed}s < ${RUNTIME_RESTART_COOLDOWN_S}s; skip restart"
      return 1
    fi
  fi

  electron_bin="$(resolve_electron || true)"
  if [[ -z "$electron_bin" || ! -x "$electron_bin" ]]; then
    log "ERROR: cannot restart runtime — Electron binary not found under $APP_ROOT"
    return 1
  fi
  if [[ ! -d "$USER_DATA_PATH" ]]; then
    log "ERROR: cannot restart runtime — user data path missing: $USER_DATA_PATH"
    return 1
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    log "ERROR: cannot restart runtime — tmux not found"
    return 1
  fi
  if [[ ! -x /usr/bin/Xvfb ]]; then
    log "ERROR: cannot restart runtime — /usr/bin/Xvfb missing"
    return 1
  fi

  log "runtime repair ($reason): restarting local headless serve (session=$RUNTIME_SESSION, no remote proxy restart)"
  kill_stale_runtime || true
  ensure_xvfb || return 1

  : >"$SERVE_LOG_PATH"
  chmod 600 "$SERVE_LOG_PATH" 2>/dev/null || true

  # Current upstream removed the legacy --serve-relay-* Electron arguments, so
  # start the supported `orca serve` CLI surface here. The relay identity is not
  # needed by the runtime; the bridge is started separately by start_bridge.
  printf -v launch_command \
    'exec env -u ELECTRON_RUN_AS_NODE DISPLAY=%q LIBGL_ALWAYS_SOFTWARE=1 ORCA_USER_DATA_PATH=%q ORCA_APP_EXECUTABLE=%q ORCA_APP_EXECUTABLE_NEEDS_APP_ROOT=1 ORCA_APPIMAGE_NO_SANDBOX=1 %q serve --port %q --pairing-address %q --mobile-pairing --json >>%q 2>&1' \
    "$DISPLAY_NUMBER" "$USER_DATA_PATH" "$electron_bin" "$CLI_BIN" \
    "$RUNTIME_PORT" "$MOBILE_PAIRING_ADDRESS" "$SERVE_LOG_PATH"

  stop_tmux_session "$RUNTIME_SESSION"
  tmux new-session -d -s "$RUNTIME_SESSION" "$launch_command"

  LAST_RUNTIME_RESTART_TS=$now
  PREV_SENT=0
  PREV_TS=0
  SENDQ_HIGH_STREAK=0
  STALL_STREAK=0
  save_state

  if wait_for_local_ready; then
    local epids bpids
    epids="$(electron_serve_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    bpids="$(bridge_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    log "runtime repair ok: runtime_pids=[$epids] bridge_pids=[$bpids]"
    return 0
  fi

  log "ERROR: runtime repair failed within ${RUNTIME_READY_TIMEOUT_S}s; tail $SERVE_LOG_PATH"
  tail -n 40 "$SERVE_LOG_PATH" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | while read -r line; do
    log "serve-log: $line"
  done || true
  return 1
}

start_bridge() {
  local launch_command pid
  if [[ -n "$(bridge_pids)" ]]; then
    return 0
  fi
  if ! runtime_port_open; then
    log "runtime :$RUNTIME_PORT is down; not starting bridge alone"
    return 1
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    log "ERROR: cannot start bridge — tmux not found"
    return 1
  fi
  : >"$BRIDGE_LOG_PATH"
  chmod 600 "$BRIDGE_LOG_PATH" 2>/dev/null || true
  stop_tmux_session "$BRIDGE_SESSION"
  # Run the bridge as its own tmux service so it survives this watchdog process.
  # The token is sourced from the env file inside the session, never passed as an
  # argument, so it cannot appear in `ps` output.
  printf -v launch_command \
    'set -a; source %q; set +a; exec %q --relay-url %q --runtime-url %q --server-id %q >>%q 2>&1' \
    "$RELAY_ENV" "$BRIDGE_PATH" "$ORCA_RELAY_URL" "$RUNTIME_URL" \
    "$ORCA_RELAY_SERVER_ID" "$BRIDGE_LOG_PATH"
  tmux new-session -d -s "$BRIDGE_SESSION" "$launch_command"
  sleep 1
  pid="$(bridge_pids | head -n 1)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid" >"$PID_PATH"
    chmod 600 "$PID_PATH" 2>/dev/null || true
    log "started bridge tmux=$BRIDGE_SESSION pid=$pid server_id=$ORCA_RELAY_SERVER_ID"
    return 0
  fi
  log "bridge exited immediately; see $BRIDGE_LOG_PATH"
  return 1
}

restart_bridge_pids() {
  local reason="$1"
  local pids
  pids="$(bridge_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  log "soft-death repair ($reason): restarting bridge pids=[$pids]"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < <(bridge_pids)
  sleep 2
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done < <(bridge_pids)
  stop_tmux_session "$BRIDGE_SESSION"
  sleep 1
  PREV_SENT=0
  PREV_TS=0
  SENDQ_HIGH_STREAK=0
  STALL_STREAK=0
  save_state

  # Nothing respawns the bridge for us; the watchdog owns its lifecycle.
  start_bridge
}

emit_status() {
  local pids runtime health connected count epids
  local sendq sent lastrcv unacked
  pids="$(bridge_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  epids="$(electron_serve_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  count="$(bridge_pids | wc -l | tr -d ' ')"
  runtime=0; runtime_port_open && runtime=1
  health=0; public_health_ok && health=1
  connected=0; bridge_connected_to_relay && connected=1
  read -r _ sendq sent lastrcv unacked _ <<<"$(bridge_tcp_stats)"
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"runtimePortOpen":%s,"electronPids":"%s","bridgeCount":%s,"bridgePids":"%s","bridgeConnected":%s,"publicHealthOk":%s,"serverId":"%s","sendq":%s,"bytesSent":%s,"lastrcvMs":%s,"unacked":%s,"sendqHighStreak":%s,"stallStreak":%s,"lastRuntimeRestartTs":%s}\n' \
      "$runtime" "$epids" "$count" "$pids" "$connected" "$health" "$ORCA_RELAY_SERVER_ID" \
      "$sendq" "$sent" "$lastrcv" "$unacked" "$SENDQ_HIGH_STREAK" "$STALL_STREAK" "${LAST_RUNTIME_RESTART_TS:-0}"
  else
    printf 'runtime_port_open=%s electron_pids=[%s] bridge_count=%s bridge_pids=[%s] bridge_connected=%s public_health_ok=%s server_id=%s sendq=%s lastrcv_ms=%s unacked=%s sendq_streak=%s stall_streak=%s last_runtime_restart_ts=%s\n' \
      "$runtime" "$epids" "$count" "$pids" "$connected" "$health" "$ORCA_RELAY_SERVER_ID" \
      "$sendq" "$lastrcv" "$unacked" "$SENDQ_HIGH_STREAK" "$STALL_STREAK" "${LAST_RUNTIME_RESTART_TS:-0}"
  fi
}

repair_once() {
  local pids count
  local sendq sent lastrcv unacked now delta_sent=0
  load_state
  pids="$(bridge_pids || true)"
  count="$(bridge_pids | wc -l | tr -d ' ')"
  now="$(date +%s)"

  # 1) Runtime gone → restart full local serve (most common outage).
  if ! runtime_port_open; then
    if [[ "$RUNTIME_REPAIR" == "1" ]]; then
      restart_local_runtime "port_${RUNTIME_PORT}_down"
      return $?
    fi
    log "skip repair: runtime port $RUNTIME_PORT not listening (RUNTIME_REPAIR=0)"
    return 1
  fi

  # 2) Runtime up but bridge missing → start the bridge service.
  if [[ "$count" -eq 0 ]]; then
    log "bridge missing while runtime up; starting local bridge"
    start_bridge
    return $?
  fi

  # 3) Bridge process exists but no public socket — half-open / soft-death.
  if ! bridge_connected_to_relay; then
    if [[ "$SOFT_DEATH_REPAIR" == "1" ]]; then
      restart_bridge_pids "no_443_socket"
      return $?
    fi
    log "bridge has no :443 socket but SOFT_DEATH_REPAIR=0"
    return 1
  fi

  read -r _ sendq sent lastrcv unacked _ <<<"$(bridge_tcp_stats)"
  if [[ "${PREV_TS:-0}" -gt 0 && "$now" -gt "$PREV_TS" && "$sent" -ge "${PREV_SENT:-0}" ]]; then
    delta_sent=$((sent - PREV_SENT))
  fi

  if [[ "$sendq" -ge "$SENDQ_WARN" ]]; then
    SENDQ_HIGH_STREAK=$((SENDQ_HIGH_STREAK + 1))
  else
    SENDQ_HIGH_STREAK=0
  fi
  if [[ "$sendq" -ge "$SENDQ_WARN" && "${PREV_TS:-0}" -gt 0 && "$delta_sent" -lt 4096 ]]; then
    STALL_STREAK=$((STALL_STREAK + 1))
  else
    STALL_STREAK=0
  fi

  PREV_SENT=$sent
  PREV_TS=$now
  save_state

  if [[ "$SOFT_DEATH_REPAIR" == "1" ]]; then
    if [[ "$STALL_STREAK" -ge "$STALL_STREAK_RESTART" ]]; then
      restart_bridge_pids "uplink_stall_streak:$STALL_STREAK sendq:$sendq delta_sent:$delta_sent"
      return $?
    fi
    if [[ "$sendq" -ge "$SENDQ_CRIT" && "$delta_sent" -lt 16384 ]]; then
      restart_bridge_pids "sendq_crit_stalled:$sendq delta_sent:$delta_sent"
      return $?
    fi
    if [[ "$SENDQ_HIGH_STREAK" -ge "$SENDQ_STREAK_RESTART" && "$delta_sent" -lt 16384 ]]; then
      restart_bridge_pids "sendq_high_stalled_streak:$SENDQ_HIGH_STREAK sendq:$sendq delta_sent:$delta_sent"
      return $?
    fi
  fi

  if [[ "$SENDQ_HIGH_STREAK" -gt 0 ]]; then
    log "ok-ish: bridge :443 up but sendq elevated (pids: $pids sendq=$sendq unacked=$unacked lastrcv=${lastrcv}ms streak=$SENDQ_HIGH_STREAK/$STALL_STREAK delta_sent=$delta_sent)"
  else
    log "ok: runtime+bridge up (pids: $pids sendq=$sendq unacked=$unacked lastrcv=${lastrcv}ms streak=$SENDQ_HIGH_STREAK/$STALL_STREAK)"
  fi
  return 0
}

case "$MODE" in
  status)
    load_state
    emit_status
    ;;
  once)
    repair_once || true
    emit_status
    ;;
  loop)
    log "entering loop interval=${INTERVAL_SECONDS}s runtime_repair=${RUNTIME_REPAIR} soft_death_repair=${SOFT_DEATH_REPAIR}"
    while true; do
      repair_once || true
      sleep "$INTERVAL_SECONDS"
    done
    ;;
esac
