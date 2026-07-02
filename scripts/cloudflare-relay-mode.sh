#!/usr/bin/env bash
set -euo pipefail

RECORD_NAME="${CF_RECORD_NAME:-relay-orca.lucaszen.dpdns.org}"
API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

usage() {
  cat <<'USAGE'
Usage: scripts/cloudflare-relay-mode.sh <grey|orange|status> [--apply]

Safely check or switch the Cloudflare A record for relay-orca.lucaszen.dpdns.org.
By default grey/orange print the intended API update without changing Cloudflare.
Pass --apply to perform the PATCH after credentials are supplied.

Required environment:
  CF_API_TOKEN   Cloudflare API token with DNS edit/read permission
  CF_ZONE_ID     Cloudflare zone id
  CF_RECORD_ID   DNS record id for relay-orca.lucaszen.dpdns.org
  ALI_VPS_IP     Ali VPS IPv4 address for the relay A record

Optional environment:
  CF_RECORD_NAME Defaults to relay-orca.lucaszen.dpdns.org
  CF_API_BASE    Defaults to https://api.cloudflare.com/client/v4
USAGE
}

missing=()
require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("$name")
    fi
  done
}

print_missing_and_exit() {
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required environment variables:" >&2
    local name
    for name in "${missing[@]}"; do
      echo "  - $name" >&2
    done
    echo "No Cloudflare request was sent." >&2
    exit 2
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

mode="${1:-}"
apply="${2:-}"
if [[ -z "$mode" || "$mode" == "-h" || "$mode" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$apply" != "" && "$apply" != "--apply" ]]; then
  usage >&2
  exit 2
fi

case "$mode" in
  grey|dns-only|dns_only)
    proxied=false
    label="grey DNS-only"
    ;;
  orange|proxied)
    proxied=true
    label="orange proxied"
    ;;
  status|check)
    proxied=""
    label="status"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ "$mode" == "status" || "$mode" == "check" ]]; then
  require_env CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID
else
  require_env CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID ALI_VPS_IP
fi
print_missing_and_exit

record_url="$API_BASE/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID"

echo "record=$RECORD_NAME"
echo "zone_id=$CF_ZONE_ID"
echo "record_id=$CF_RECORD_ID"
echo "mode=$label"

if [[ "$mode" == "status" || "$mode" == "check" ]]; then
  curl --fail --silent --show-error \
    --request GET "$record_url" \
    --header "Authorization: Bearer $CF_API_TOKEN" \
    --header "Content-Type: application/json" \
    | python3 -m json.tool
  exit 0
fi

payload="{\"type\":\"A\",\"name\":$(json_escape "$RECORD_NAME"),\"content\":$(json_escape "$ALI_VPS_IP"),\"proxied\":$proxied,\"ttl\":1}"

if [[ "$apply" != "--apply" ]]; then
  echo "dry_run=true"
  echo "Would PATCH $record_url"
  echo "Would set content=$ALI_VPS_IP proxied=$proxied ttl=1"
  echo "Re-run with --apply to send the Cloudflare request. CF_API_TOKEN is never printed."
  exit 0
fi

echo "dry_run=false"
curl --fail --silent --show-error \
  --request PATCH "$record_url" \
  --header "Authorization: Bearer $CF_API_TOKEN" \
  --header "Content-Type: application/json" \
  --data "$payload" \
  | python3 -m json.tool
