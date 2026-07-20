#!/usr/bin/env bash
# Soft-death probe for the runtime-host <-> VPS orca-relay path.
#
# Process-level health (bridge pid + :443 ESTAB + /health) can stay green while
# the application session is already dead. This probe samples TCP/client side
# signals and freezes evidence on warn/crit. It never restarts services.
#
# Usage:
#   bash scripts/orca-relay-soft-death-probe.sh
#   bash scripts/orca-relay-soft-death-probe.sh --loop
#   bash scripts/orca-relay-soft-death-probe.sh --status --json
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

BRIDGE_PATH="${ORCA_RELAY_BRIDGE_PATH:-$REPO_ROOT/target/release/orca-relay-bridge}"
INTERVAL_SECONDS="${ORCA_SOFT_DEATH_INTERVAL_SECONDS:-30}"
SNAP_DIR="${ORCA_SOFT_DEATH_DIR:-/tmp/orca-relay-soft-death}"
REMOTE_HOST="${ORCA_SOFT_DEATH_REMOTE_HOST:-ali}"
REMOTE_DIR="${ORCA_SOFT_DEATH_REMOTE_DIR:-/var/tmp/orca-relay-soft-death}"
SENDQ_WARN="${ORCA_SOFT_DEATH_SENDQ_WARN:-65536}"
SENDQ_CRIT="${ORCA_SOFT_DEATH_SENDQ_CRIT:-200000}"
LASTRCV_STALE_MS="${ORCA_SOFT_DEATH_LASTRCV_STALE_MS:-60000}"
RELAY_HEALTH_URL="${ORCA_RELAY_HEALTH_URL:-https://<your-relay-domain.example>/health}"
HTTP_PROXY_URL="${ORCA_WATCHDOG_HTTP_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
RUNTIME_PORT="${ORCA_RUNTIME_PORT:-6768}"
DEVICES_JSON="${ORCA_DEVICES_JSON:-/root/.config/orca-dev/orca-devices.json}"
RELAY_ENV="${ORCA_RELAY_ENV_FILE:-/root/.config/orca/orca-relay.env}"
MODE="once"
JSON=0

STATE_FILE="$SNAP_DIR/state.env"
LOG_PATH="$SNAP_DIR/probe.log"
PREV_SENT=0
PREV_RCV=0
PREV_TS=0
SENDQ_HIGH_STREAK=0
STALL_STREAK=0
ORCA_RELAY_SERVER_ID="${ORCA_RELAY_SERVER_ID:-unknown}"

usage() {
  cat <<'EOF'
Soft-death evidence probe for orca-relay (local + remote VPS). Does not restart anything.

Usage:
  bash scripts/orca-relay-soft-death-probe.sh [--once|--loop|--status] [--json]

Env overrides:
  ORCA_RELAY_BRIDGE_PATH / ORCA_RELAY_ENV_FILE / ORCA_RELAY_HEALTH_URL
  ORCA_SOFT_DEATH_DIR / ORCA_SOFT_DEATH_REMOTE_HOST / ORCA_SOFT_DEATH_REMOTE_DIR
  ORCA_SOFT_DEATH_INTERVAL_SECONDS / ORCA_SOFT_DEATH_SENDQ_WARN
  ORCA_SOFT_DEATH_SENDQ_CRIT / ORCA_SOFT_DEATH_LASTRCV_STALE_MS
  ORCA_WATCHDOG_HTTP_PROXY / ORCA_RUNTIME_PORT / ORCA_DEVICES_JSON
EOF
}

log() {
  mkdir -p "$SNAP_DIR"
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_PATH" >&2
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

mkdir -p "$SNAP_DIR"
chmod 700 "$SNAP_DIR" 2>/dev/null || true

if [[ -r "$RELAY_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$RELAY_ENV"
  set +a
fi

load_state() {
  [[ -r "$STATE_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
}

save_state() {
  cat >"$STATE_FILE" <<EOF
PREV_SENT=${PREV_SENT}
PREV_RCV=${PREV_RCV}
PREV_TS=${PREV_TS}
SENDQ_HIGH_STREAK=${SENDQ_HIGH_STREAK}
STALL_STREAK=${STALL_STREAK}
EOF
}

bridge_pids() {
  ps -eo pid=,args= | awk -v bridge="$BRIDGE_PATH" '
    $0 ~ bridge && /--relay-url/ && /--server-id/ && $0 !~ /electron/ && $0 !~ /watchdog/ && $0 !~ /soft-death/ { print $1 }
  '
}

runtime_port_open() {
  ss -ltn 2>/dev/null | awk -v p=":$RUNTIME_PORT" '$4 ~ p"$" { found=1 } END { exit !found }'
}

public_health_ok() {
  local args=( -fsS --max-time 8 )
  if [[ -n "${HTTP_PROXY_URL:-}" ]]; then
    args+=( -x "$HTTP_PROXY_URL" )
  fi
  local body
  body="$(curl "${args[@]}" "$RELAY_HEALTH_URL" 2>/dev/null || true)"
  grep -q '"status":"ok"' <<<"$body"
}

# Emits: pid sendq recvq bytes_sent bytes_rcv lastrcv lastsnd unacked rtt peer connected
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
        and "soft-death" not in line
    ):
        pids.append(line.strip().split()[0])
if not pids:
    print("0 0 0 0 0 -1 -1 0 0 none 0")
    raise SystemExit
pid = pids[0]
out = subprocess.check_output(["ss", "-Htnpi", "dst", ":443"], text=True, stderr=subprocess.DEVNULL)
blocks = out.splitlines()
head = info = ""
for i, line in enumerate(blocks):
    if f"pid={pid}," in line and ":443" in line:
        head = line
        if i + 1 < len(blocks) and not blocks[i + 1].startswith("ESTAB") and "users:(" not in blocks[i + 1][:20]:
            # next line may be tcp detail starting with spaces/tabs
            if re.search(r"\b(bbr|cubic|rtt:|bytes_sent:)", blocks[i + 1]):
                info = blocks[i + 1]
        # sometimes detail is on same multi-line; also scan nearby
        if not info:
            for j in range(i + 1, min(i + 3, len(blocks))):
                if re.search(r"bytes_sent:|rtt:", blocks[j]):
                    info = blocks[j]
                    break
        break
if not head:
    # fallback without filter
    out = subprocess.check_output(["ss", "-tnpi"], text=True, stderr=subprocess.DEVNULL)
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if f"pid={pid}," in line and ":443" in line:
            head = line
            for j in range(i + 1, min(i + 3, len(lines))):
                if re.search(r"bytes_sent:|rtt:", lines[j]):
                    info = lines[j]
                    break
            break
if not head:
    print(f"{pid} 0 0 0 0 -1 -1 0 0 none 0")
    raise SystemExit
parts = head.split()
recvq = sendq = 0
peer = "none"
# formats: ESTAB Recv-Q Send-Q Local Peer users:(...)
try:
    # when -H, first field is state
    if parts[0] in {"ESTAB", "ESTABLISHED"}:
        recvq = int(parts[1]); sendq = int(parts[2]); peer = parts[4]
    else:
        recvq = int(parts[0]); sendq = int(parts[1]); peer = parts[3]
except Exception:
    pass
def g(pat, default):
    m = re.search(pat, info)
    return m.group(1) if m else default
sent = g(r"bytes_sent:(\d+)", "0")
rcv = g(r"bytes_received:(\d+)", "0")
lastrcv = g(r"lastrcv:(\d+)", "-1")
lastsnd = g(r"lastsnd:(\d+)", "-1")
unacked = g(r"unacked:(\d+)", "0")
rtt = g(r"rtt:([0-9.]+)", "0")
print(pid, sendq, recvq, sent, rcv, lastrcv, lastsnd, unacked, rtt, peer, 1)
PY
}

device_ages_json() {
  DEVICES_JSON="$DEVICES_JSON" python3 - <<'PY'
import json, os, time
from pathlib import Path
path = Path(os.environ.get("DEVICES_JSON", "/root/.config/orca-dev/orca-devices.json"))
now = time.time() * 1000
out = []
if path.exists():
    try:
        for d in json.loads(path.read_text()):
            ls = d.get("lastSeenAt") or 0
            age = None if not ls else round((now - ls) / 1000.0, 1)
            out.append({"name": d.get("name"), "scope": d.get("scope"), "lastSeenAgeSec": age})
    except Exception as e:
        out = [{"error": str(e)}]
print(json.dumps(out, separators=(",", ":")))
PY
}

git_exec_rate() {
  python3 - <<'PY'
import json, time
from pathlib import Path
trace = Path("/root/.config/orca-dev/logs/main.trace.ndjson")
if not trace.exists():
    print("0 0 0")
    raise SystemExit
now = time.time()
count = fail = worktree = 0
data = trace.read_bytes()[-600000:].decode("utf-8", "ignore")
for line in data.splitlines():
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("type") != "effect-span" or o.get("name") != "git.exec":
        continue
    ts = o.get("startTimeUnixNano")
    if not ts:
        continue
    sec = int(int(ts) / 1e9)
    if now - sec > 30:
        continue
    count += 1
    attrs = o.get("attributes") or {}
    if attrs.get("git.subcommand") == "worktree":
        worktree += 1
    if (o.get("exit") or {}).get("_tag") == "Failure":
        fail += 1
print(count, worktree, fail)
PY
}

freeze_snapshot() {
  local reason="$1"
  local stamp dir remote_stamp
  stamp="$(date '+%Y%m%dT%H%M%S%z')"
  dir="$SNAP_DIR/snap-$stamp"
  mkdir -p "$dir"
  {
    echo "reason=$reason"
    echo "host=$(hostname)"
    echo "date=$(date -Is)"
    echo "server_id=${ORCA_RELAY_SERVER_ID:-unknown}"
  } >"$dir/meta.txt"

  {
    echo '=== bridge pids ==='
    bridge_pids || true
    echo '=== ss bridge tcp ==='
    ss -Htnpi dst :443 2>/dev/null | head -40 || true
    echo '=== ss runtime ==='
    ss -tnp 2>/dev/null | grep -E ":$RUNTIME_PORT|:443" | head -80 || true
    echo '=== processes ==='
    ps -eo pid,ppid,pcpu,pmem,rss,etime,cmd | grep -iE 'orca-relay|electron.*--serve|shell-ready' | grep -v grep | head -40 || true
    echo '=== devices ==='
    device_ages_json
    echo '=== git rate count worktree fail ==='
    git_exec_rate
  } >"$dir/local.txt" 2>&1 || true

  [[ -r /tmp/orca-serve-relay.log ]] && tail -n 120 /tmp/orca-serve-relay.log >"$dir/serve-relay.tail.log" 2>/dev/null || true
  [[ -r /tmp/orca-relay-bridge-watchdog.log ]] && tail -n 80 /tmp/orca-relay-bridge-watchdog.log >"$dir/watchdog.tail.log" 2>/dev/null || true

  REMOTE_SERVICES="${ORCA_SOFT_DEATH_REMOTE_SERVICES:-orca-relay orca-relay-proxy-wx29 orca-relay-proxy-mobile caddy}"
  remote_stamp="snap-$stamp"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" \
    "mkdir -p '$REMOTE_DIR/$remote_stamp' && {
      date -Is
      echo reason=$reason
      systemctl is-active $REMOTE_SERVICES || true
      echo '=== 6769 ==='
      ss -Htn state established '( sport = :6769 or dport = :6769 )' || true
      echo '=== 6770 ==='
      ss -Htn state established '( sport = :6770 or dport = :6770 )' || true
      echo '=== 6771 ==='
      ss -Htn state established '( sport = :6771 or dport = :6771 )' || true
      echo '=== :443 peers ==='
      ss -tni state established '( sport = :443 )' || true
      echo '=== journal orca-relay ==='
      journalctl -u orca-relay.service -n 80 --no-pager || true
      echo '=== journal proxies ==='
      for unit in $REMOTE_SERVICES; do
        case \"\$unit\" in
          orca-relay|caddy) continue ;;
          *) journalctl -u \"\$unit.service\" -n 40 --no-pager || true ;;
        esac
      done
    } >'$REMOTE_DIR/$remote_stamp/ali.txt' 2>&1" \
    >"$dir/remote-ssh.txt" 2>&1 || true

  log "SNAPSHOT frozen reason=$reason dir=$dir remote=$REMOTE_HOST:$REMOTE_DIR/$remote_stamp"
  printf '%s\n' "$dir"
}

sample_once() {
  load_state
  local now pid sendq recvq sent rcv lastrcv lastsnd unacked rtt peer connected
  local runtime health bridge_count
  local git_count git_worktree git_fail
  local uplink_bps=0 downlink_bps=0
  local severity="ok"
  local reasons=()

  now="$(date +%s)"
  read -r pid sendq recvq sent rcv lastrcv lastsnd unacked rtt peer connected <<<"$(bridge_tcp_stats)"
  bridge_count="$(bridge_pids | wc -l | tr -d ' ')"
  runtime=0; runtime_port_open && runtime=1
  health=0; public_health_ok && health=1
  read -r git_count git_worktree git_fail <<<"$(git_exec_rate)"

  if [[ "${PREV_TS:-0}" -gt 0 && "$now" -gt "$PREV_TS" ]]; then
    local dt=$((now - PREV_TS))
    if [[ "$dt" -gt 0 && "$sent" -ge "${PREV_SENT:-0}" && "$rcv" -ge "${PREV_RCV:-0}" ]]; then
      uplink_bps=$(( (sent - PREV_SENT) / dt ))
      downlink_bps=$(( (rcv - PREV_RCV) / dt ))
    fi
  fi

  if [[ "$sendq" -ge "$SENDQ_WARN" ]]; then
    SENDQ_HIGH_STREAK=$((SENDQ_HIGH_STREAK + 1))
  else
    SENDQ_HIGH_STREAK=0
  fi

  if [[ "$sendq" -ge "$SENDQ_WARN" && "${PREV_TS:-0}" -gt 0 && $((sent - PREV_SENT)) -lt 4096 ]]; then
    STALL_STREAK=$((STALL_STREAK + 1))
  else
    STALL_STREAK=0
  fi

  if [[ "$runtime" -eq 0 ]]; then severity="warn"; reasons+=("runtime_down"); fi
  if [[ "$bridge_count" -eq 0 ]]; then severity="crit"; reasons+=("bridge_missing"); fi
  if [[ "$bridge_count" -gt 0 && "$connected" -eq 0 ]]; then severity="crit"; reasons+=("bridge_no_443"); fi
  if [[ "$sendq" -ge "$SENDQ_CRIT" ]]; then
    severity="crit"; reasons+=("sendq_crit:$sendq")
  elif [[ "$SENDQ_HIGH_STREAK" -ge 3 ]]; then
    [[ "$severity" == "ok" ]] && severity="warn"
    reasons+=("sendq_high_streak:$SENDQ_HIGH_STREAK:$sendq")
  fi
  if [[ "$STALL_STREAK" -ge 2 ]]; then severity="crit"; reasons+=("uplink_stall_streak:$STALL_STREAK"); fi
  if [[ "$lastrcv" != "-1" && "$lastrcv" -ge "$LASTRCV_STALE_MS" && "$connected" -eq 1 ]]; then
    if [[ "$uplink_bps" -lt 1000 && "$downlink_bps" -lt 1000 ]]; then
      severity="crit"; reasons+=("lastrcv_stale_ms:$lastrcv")
    else
      reasons+=("lastrcv_elevated_ms:$lastrcv")
      [[ "$severity" == "ok" ]] && severity="warn"
    fi
  fi
  if [[ "$health" -eq 0 ]]; then
    [[ "$severity" == "ok" ]] && severity="warn"
    reasons+=("public_health_bad")
  fi

  local reason_str="none"
  if [[ ${#reasons[@]} -gt 0 ]]; then
    reason_str=$(IFS=,; echo "${reasons[*]}")
  fi

  PREV_SENT=$sent
  PREV_RCV=$rcv
  PREV_TS=$now
  save_state

  local devices
  devices="$(device_ages_json)"

  if [[ "$JSON" -eq 1 ]]; then
    printf '{"severity":"%s","reasons":"%s","runtimePortOpen":%s,"bridgeCount":%s,"bridgePid":"%s","bridgeConnected":%s,"publicHealthOk":%s,"sendq":%s,"recvq":%s,"bytesSent":%s,"bytesRcv":%s,"uplinkBps":%s,"downlinkBps":%s,"lastrcvMs":%s,"lastsndMs":%s,"unacked":%s,"rttMs":%s,"peer":"%s","sendqHighStreak":%s,"stallStreak":%s,"gitExec30s":%s,"gitWorktree30s":%s,"gitFail30s":%s,"devices":%s}\n' \
      "$severity" "$reason_str" "$runtime" "$bridge_count" "$pid" "$connected" "$health" \
      "$sendq" "$recvq" "$sent" "$rcv" "$uplink_bps" "$downlink_bps" \
      "$lastrcv" "$lastsnd" "$unacked" "$rtt" "$peer" \
      "$SENDQ_HIGH_STREAK" "$STALL_STREAK" \
      "$git_count" "$git_worktree" "$git_fail" "$devices"
  else
    log "severity=$severity reasons=$reason_str runtime=$runtime bridge=$bridge_count/$pid connected=$connected health=$health sendq=$sendq unacked=$unacked uplink=${uplink_bps}B/s downlink=${downlink_bps}B/s lastrcv=${lastrcv}ms git30s=$git_count worktree=$git_worktree fail=$git_fail"
  fi

  if [[ "$severity" == "warn" || "$severity" == "crit" ]]; then
    local lock="$SNAP_DIR/last-freeze.ts"
    local last=0
    [[ -r "$lock" ]] && last="$(cat "$lock" 2>/dev/null || echo 0)"
    if [[ "$severity" == "crit" || $((now - last)) -ge 120 ]]; then
      echo "$now" >"$lock"
      freeze_snapshot "$reason_str" >/dev/null || true
    fi
  fi
}

case "$MODE" in
  status) JSON=1; sample_once ;;
  once) sample_once ;;
  loop)
    log "entering soft-death probe loop interval=${INTERVAL_SECONDS}s dir=$SNAP_DIR"
    while true; do
      sample_once || true
      sleep "$INTERVAL_SECONDS"
    done
    ;;
esac
