#!/usr/bin/env bash
# Keep the Orca relay watchdog alive outside any terminal, tmux pane, or SSH session.
#
# The watchdog itself only loops; it dies with whatever shell started it. This
# supervisor detaches it with setsid, enforces a single instance with flock, and
# tracks it by pid so `start` is idempotent and safe to call from cron, a login
# profile, or an agent runbook.
#
# Usage:
#   bash scripts/orca-relay-watchdog-daemon.sh start
#   bash scripts/orca-relay-watchdog-daemon.sh status
#   bash scripts/orca-relay-watchdog-daemon.sh stop
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

WATCHDOG="${ORCA_WATCHDOG_SCRIPT:-$SCRIPT_DIR/orca-relay-bridge-watchdog.sh}"
PID_FILE="${ORCA_WATCHDOG_DAEMON_PID_PATH:-/tmp/orca-relay-watchdog-daemon.pid}"
LOCK_FILE="${ORCA_WATCHDOG_DAEMON_LOCK_PATH:-/tmp/orca-relay-watchdog-daemon.lock}"
LOG_FILE="${ORCA_WATCHDOG_DAEMON_LOG_PATH:-/tmp/orca-relay-watchdog-daemon.log}"

usage() {
  cat <<'EOF'
Supervise scripts/orca-relay-bridge-watchdog.sh --loop as a detached singleton.

Usage:
  bash scripts/orca-relay-watchdog-daemon.sh {start|stop|status|run}

  start   Start the watchdog loop if it is not already running (idempotent).
  stop    Signal the watchdog loop and wait for the singleton lock to clear.
  status  Print "running pid=<pid>" and exit 0, or "stopped" and exit 1.
  run     Foreground supervisor body. Used internally by start; not for operators.

Env overrides:
  ORCA_WATCHDOG_SCRIPT             Watchdog script path
  ORCA_WATCHDOG_DAEMON_PID_PATH    Default /tmp/orca-relay-watchdog-daemon.pid
  ORCA_WATCHDOG_DAEMON_LOCK_PATH   Default /tmp/orca-relay-watchdog-daemon.lock
  ORCA_WATCHDOG_DAEMON_LOG_PATH    Default /tmp/orca-relay-watchdog-daemon.log

The watchdog reads its own ORCA_* overrides; see orca-relay-bridge-watchdog.sh --help.
EOF
}

read_pid() {
  local pid=''
  if [[ -r "$PID_FILE" ]]; then
    read -r pid <"$PID_FILE" || true
  fi
  printf '%s' "$pid"
}

is_running() {
  local pid="$1"
  [[ -n "$pid" && -d "/proc/$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Confirm the pid is really our watchdog loop and not a recycled pid.
  tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | grep -Fq "$WATCHDOG --loop"
}

start() {
  local pid
  pid="$(read_pid)"
  if is_running "$pid"; then
    return 0
  fi
  rm -f "$PID_FILE"
  [[ -r "$WATCHDOG" ]] || {
    printf 'watchdog script not readable: %s\n' "$WATCHDOG" >&2
    return 1
  }
  nohup setsid "$SCRIPT_PATH" run >>"$LOG_FILE" 2>&1 </dev/null &
  for _ in $(seq 1 20); do
    pid="$(read_pid)"
    if is_running "$pid"; then
      return 0
    fi
    sleep 0.1
  done
  if ! flock -n "$LOCK_FILE" true 2>/dev/null; then
    printf 'another watchdog supervisor already holds %s\n' "$LOCK_FILE" >&2
    return 1
  fi
  printf 'failed to start Orca relay watchdog; see %s\n' "$LOG_FILE" >&2
  return 1
}

stop() {
  local pid
  pid="$(read_pid)"
  if is_running "$pid"; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      is_running "$pid" || break
      sleep 0.1
    done
    # Wait for the supervisor to release the singleton lock before returning, so
    # an immediate restart cannot race the outgoing instance.
    for _ in $(seq 1 30); do
      flock -n "$LOCK_FILE" true 2>/dev/null && break
      sleep 0.1
    done
  fi
  rm -f "$PID_FILE"
}

status() {
  local pid
  pid="$(read_pid)"
  if is_running "$pid"; then
    printf 'running pid=%s\n' "$pid"
    return 0
  fi
  printf 'stopped\n'
  return 1
}

run() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 0
  local child_pid=''
  cleanup() {
    rm -f "$PID_FILE"
    if [[ -n "$child_pid" ]]; then
      kill "$child_pid" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT HUP INT TERM

  # Keep the singleton lock in this supervisor. Closing fd 9 in the watchdog
  # prevents long-lived tmux children from inheriting it and pinning the lock
  # after this supervisor exits.
  bash "$WATCHDOG" --loop 9>&- &
  child_pid="$!"
  printf '%s\n' "$child_pid" >"$PID_FILE"
  wait "$child_pid"
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  run) run ;;
  -h|--help) usage; exit 0 ;;
  *)
    printf 'usage: %s {start|stop|status|run}\n' "${0##*/}" >&2
    exit 2
    ;;
esac
