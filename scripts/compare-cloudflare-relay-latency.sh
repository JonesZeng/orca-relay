#!/usr/bin/env bash
set -euo pipefail

URL="${ORCA_RELAY_WS_URL:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/compare-cloudflare-relay-latency.sh

Compare orca-relay WebSocket latency through Cloudflare grey DNS-only and
orange proxied modes. The script changes Cloudflare only when APPLY=1.
It never prints the bearer token.

Required environment:
  ORCA_RELAY_WS_URL   wss://relay-orca.lucaszen.dpdns.org/ws?... endpoint
  ORCA_RELAY_TOKEN    Relay bearer token
  CF_API_TOKEN        Cloudflare API token
  CF_ZONE_ID          Cloudflare zone id
  CF_RECORD_ID        DNS record id
  ALI_VPS_IP          Ali VPS IPv4 address

Optional environment:
  APPLY=1             Actually switch Cloudflare modes; default is dry-run only
  SETTLE_SECONDS=30   Wait after each switch before probing; default 30
  RUNS=3              Probe count per mode; default 3
USAGE
}

missing=()
for name in ORCA_RELAY_WS_URL ORCA_RELAY_TOKEN CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID ALI_VPS_IP; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
done

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( ${#missing[@]} > 0 )); then
  echo "Missing required environment variables:" >&2
  for name in "${missing[@]}"; do
    echo "  - $name" >&2
  done
  echo "No network request was sent." >&2
  exit 2
fi

runs="${RUNS:-3}"
settle="${SETTLE_SECONDS:-30}"
apply_flag=""
if [[ "${APPLY:-0}" == "1" ]]; then
  apply_flag="--apply"
fi

for mode in grey orange; do
  echo "=== mode=$mode ==="
  scripts/cloudflare-relay-mode.sh "$mode" $apply_flag
  if [[ -n "$apply_flag" ]]; then
    echo "waiting ${settle}s for DNS/edge propagation"
    sleep "$settle"
  else
    echo "dry_run=true; set APPLY=1 to switch Cloudflare before measuring"
  fi

  for ((i = 1; i <= runs; i++)); do
    echo "--- probe $i/$runs mode=$mode ---"
    scripts/measure-relay-ws-latency.py --url "$URL"
  done
done
