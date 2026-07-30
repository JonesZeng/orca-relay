#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"
COMMAND="install"
DOMAIN="${ORCA_RELAY_DOMAIN:-}"
BIND="${ORCA_RELAY_BIND:-127.0.0.1:8080}"
VERSION="${ORCA_RELAY_VERSION:-}"
ASSET_BASE_URL="${ORCA_RELAY_ASSET_BASE_URL:-}"
INSTALL_DIR="${ORCA_RELAY_INSTALL_DIR:-/opt/orca-relay}"
CONFIG_DIR="${ORCA_RELAY_CONFIG_DIR:-/etc/orca-relay}"
STATE_DIR="${ORCA_RELAY_STATE_DIR:-/var/lib/orca-relay}"
SERVICE_USER="${ORCA_RELAY_SERVICE_USER:-orca-relay}"
SERVICE_NAME="${ORCA_RELAY_SERVICE_NAME:-orca-relay.service}"
CADDY_MODE="${ORCA_RELAY_CADDY_MODE:-managed}"
CADDYFILE="${ORCA_RELAY_CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_SITE="${ORCA_RELAY_CADDY_SITE:-/etc/caddy/conf.d/orca-relay.caddy}"
RUST_LOG_VALUE="${ORCA_RELAY_RUST_LOG:-info}"
DRY_RUN=0
FORCE=0
PURGE=0
TOKEN=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-vps.sh [install] [options]
  scripts/install-vps.sh render [options]
  scripts/install-vps.sh rollback [options]
  scripts/install-vps.sh uninstall [options]

Install Orca Relay as a Linux/systemd VPS service behind an optional Caddy
reverse proxy. Relay tokens are accepted only through ORCA_RELAY_TOKEN or
ORCA_RELAY_TOKEN_FILE; there is intentionally no --token flag.

Commands:
  install     Install or update the service. Default command.
  render      Print generated env/unit/Caddy files with secrets redacted.
  rollback    Restore the latest installer snapshot.
  uninstall   Stop and disable the service. Keeps config/state unless --purge.

Options:
  --domain <hostname>                 Public hostname for Caddy managed mode
  --bind <host:port>                  Relay loopback bind (default 127.0.0.1:8080)
  --version <tag>                     Release tag/build id for downloaded assets
  --asset-base-url <url>              Base URL containing release tarball assets
  --install-dir <path>                Default /opt/orca-relay
  --config-dir <path>                 Default /etc/orca-relay
  --state-dir <path>                  Default /var/lib/orca-relay
  --service-user <name>               Default orca-relay
  --service-name <name.service>       Default orca-relay.service
  --caddy-mode <managed|render-only|skip>
  --caddyfile <path>                  Default /etc/caddy/Caddyfile
  --caddy-site <path>                 Default /etc/caddy/conf.d/orca-relay.caddy
  --dry-run                           Print plan and generated files; no writes
  --force                             Allow update over an existing install
  --purge                             With uninstall, remove config/state too
  -h, --help                          Show this help

Secret environment:
  ORCA_RELAY_TOKEN                    Relay bearer token value
  ORCA_RELAY_TOKEN_FILE               File whose first line is the token

Automation environment mirrors non-secret flags with ORCA_RELAY_* names.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 2
}

warn() {
  echo "warning: $*" >&2
}

info() {
  echo "$*"
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    install|render|rollback|uninstall)
      COMMAND="$1"
      shift
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      shift; [[ $# -gt 0 ]] || die "--domain requires a value"; DOMAIN="$1"
      ;;
    --bind)
      shift; [[ $# -gt 0 ]] || die "--bind requires a value"; BIND="$1"
      ;;
    --version)
      shift; [[ $# -gt 0 ]] || die "--version requires a value"; VERSION="$1"
      ;;
    --asset-base-url)
      shift; [[ $# -gt 0 ]] || die "--asset-base-url requires a value"; ASSET_BASE_URL="$1"
      ;;
    --install-dir)
      shift; [[ $# -gt 0 ]] || die "--install-dir requires a value"; INSTALL_DIR="$1"
      ;;
    --config-dir)
      shift; [[ $# -gt 0 ]] || die "--config-dir requires a value"; CONFIG_DIR="$1"
      ;;
    --state-dir)
      shift; [[ $# -gt 0 ]] || die "--state-dir requires a value"; STATE_DIR="$1"
      ;;
    --service-user)
      shift; [[ $# -gt 0 ]] || die "--service-user requires a value"; SERVICE_USER="$1"
      ;;
    --service-name)
      shift; [[ $# -gt 0 ]] || die "--service-name requires a value"; SERVICE_NAME="$1"
      ;;
    --caddy-mode)
      shift; [[ $# -gt 0 ]] || die "--caddy-mode requires a value"; CADDY_MODE="$1"
      ;;
    --caddyfile)
      shift; [[ $# -gt 0 ]] || die "--caddyfile requires a value"; CADDYFILE="$1"
      ;;
    --caddy-site)
      shift; [[ $# -gt 0 ]] || die "--caddy-site requires a value"; CADDY_SITE="$1"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --force)
      FORCE=1
      ;;
    --purge)
      PURGE=1
      ;;
    --token|--relay-token|--orca-relay-token)
      die "relay tokens must come from ORCA_RELAY_TOKEN or ORCA_RELAY_TOKEN_FILE, not CLI flags"
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

case "$CADDY_MODE" in
  managed|render-only|skip) ;;
  *) die "--caddy-mode must be managed, render-only, or skip" ;;
esac

# Managed Caddy writes a real site block and reloads Caddy. Without a hostname it
# would install the documentation placeholder and then fail certificate issuance,
# so refuse the mutating install. render and --dry-run still preview freely.
if [[ "$COMMAND" == "install" && "$DRY_RUN" != "1" && "$CADDY_MODE" == "managed" && -z "$DOMAIN" ]]; then
  die "--caddy-mode managed requires --domain (or ORCA_RELAY_DOMAIN); use --caddy-mode skip when you terminate TLS yourself"
fi

ENV_FILE="$CONFIG_DIR/orca-relay.env"
UNIT_FILE="/etc/systemd/system/$SERVICE_NAME"
CURRENT_LINK="$INSTALL_DIR/current"
SNAPSHOT_ROOT="$STATE_DIR/installer-snapshots"

require_root() {
  if [[ "$DRY_RUN" == "1" || "$COMMAND" == "render" ]]; then
    return 0
  fi
  [[ "${EUID:-$(id -u)}" == "0" ]] || die "$COMMAND requires root; re-run with sudo or use --dry-run/render"
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
  fi
}

load_token() {
  if [[ -n "${ORCA_RELAY_TOKEN_FILE:-}" ]]; then
    [[ -r "$ORCA_RELAY_TOKEN_FILE" ]] || die "cannot read ORCA_RELAY_TOKEN_FILE=$ORCA_RELAY_TOKEN_FILE"
    IFS= read -r TOKEN <"$ORCA_RELAY_TOKEN_FILE" || true
    TOKEN="${TOKEN%$'\r'}"
  elif [[ -n "${ORCA_RELAY_TOKEN:-}" ]]; then
    TOKEN="$ORCA_RELAY_TOKEN"
  else
    TOKEN="$(generate_token)"
  fi
  [[ -n "$TOKEN" ]] || die "empty relay token"
}

render_env() {
  local token_value="$1"
  cat <<EOF
# Generated by $PROGRAM.
# Do not commit this file. It contains the relay bearer token.
ORCA_RELAY_BIND=$BIND
ORCA_RELAY_TOKEN=$token_value
RUST_LOG=$RUST_LOG_VALUE
EOF
}

render_unit() {
  cat <<EOF
[Unit]
Description=orca-relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$CURRENT_LINK
EnvironmentFile=$ENV_FILE
ExecStart=$CURRENT_LINK/orca-relay
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
EOF
}

render_caddy() {
  local domain="${DOMAIN:-<your-relay-domain.example>}"
  cat <<EOF
$domain {
    encode zstd gzip

    reverse_proxy $BIND {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote_host}
    }
}
EOF
}

print_rendered_files() {
  load_token
  info "# Effective plan"
  info "command=$COMMAND"
  info "domain=${DOMAIN:-<none>}"
  info "bind=$BIND"
  info "version=${VERSION:-<none>}"
  info "install_dir=$INSTALL_DIR"
  info "config_dir=$CONFIG_DIR"
  info "state_dir=$STATE_DIR"
  info "service_name=$SERVICE_NAME"
  info "caddy_mode=$CADDY_MODE"
  info ""
  info "# $ENV_FILE"
  render_env '<redacted>'
  info ""
  info "# $UNIT_FILE"
  render_unit
  if [[ "$CADDY_MODE" != "skip" ]]; then
    info ""
    info "# $CADDY_SITE"
    render_caddy
  fi
}

write_file() {
  local path="$1"
  local mode="$2"
  local owner_group="$3"
  local dir tmp
  dir="$(dirname "$path")"
  install -d -m 0755 "$dir"
  tmp="$(mktemp "$dir/.${path##*/}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  chown "$owner_group" "$tmp"
  mv -f "$tmp" "$path"
}

snapshot_existing() {
  local ts snapshot
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot="$SNAPSHOT_ROOT/$ts"
  install -d -m 0750 "$snapshot"
  for path in "$ENV_FILE" "$UNIT_FILE" "$CADDY_SITE" "$CADDYFILE"; do
    if [[ -e "$path" ]]; then
      cp -a "$path" "$snapshot/$(echo "$path" | tr '/' '_')"
    fi
  done
  if [[ -L "$CURRENT_LINK" ]]; then
    readlink "$CURRENT_LINK" >"$snapshot/current-target.txt"
  fi
  cat >"$snapshot/metadata.env" <<EOF
COMMAND=$COMMAND
VERSION=$VERSION
BIND=$BIND
DOMAIN=$DOMAIN
SERVICE_NAME=$SERVICE_NAME
CADDY_MODE=$CADDY_MODE
EOF
  info "$snapshot"
}

ensure_user_and_dirs() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$INSTALL_DIR" "$STATE_DIR" "$SNAPSHOT_ROOT"
  install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
}

asset_target() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    *) die "unsupported architecture: $(uname -m); set ORCA_RELAY_BINARY to a local binary" ;;
  esac
}

download_release() {
  local release_dir="$1"
  local target base asset_name url archive checksum_url
  [[ -n "$VERSION" ]] || die "no local binary found; pass --version or set ORCA_RELAY_BINARY"
  target="$(asset_target)"
  if [[ -n "$ASSET_BASE_URL" ]]; then
    base="${ASSET_BASE_URL%/}"
  else
    base="https://github.com/${ORCA_RELAY_GITHUB_REPO:-JonesZeng/orca-relay}/releases/download/$VERSION"
  fi
  asset_name="orca-relay-$VERSION-$target.tar.gz"
  url="$base/$asset_name"
  archive="$release_dir/$asset_name"
  checksum_url="$url.sha256"
  command -v curl >/dev/null 2>&1 || die "curl is required to download release assets"
  command -v tar >/dev/null 2>&1 || die "tar is required to unpack release assets"
  curl -fsSL "$url" -o "$archive"
  if curl -fsSL "$checksum_url" -o "$archive.sha256"; then
    (cd "$release_dir" && sha256sum -c "${archive##*/}.sha256")
  else
    warn "checksum file not found at $checksum_url; release process should publish checksums"
  fi
  tar -xzf "$archive" -C "$release_dir"
  if [[ ! -x "$release_dir/orca-relay" ]]; then
    local found
    found="$(find "$release_dir" -type f -name orca-relay -perm -111 | head -n 1 || true)"
    [[ -n "$found" ]] || die "downloaded asset did not contain executable orca-relay"
    cp "$found" "$release_dir/orca-relay"
    chmod 0755 "$release_dir/orca-relay"
  fi
}

install_binary() {
  local release_id release_dir source_binary tmp_link
  release_id="${VERSION:-manual-$(date -u +%Y%m%dT%H%M%SZ)}"
  release_dir="$INSTALL_DIR/releases/$release_id"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$release_dir"

  if [[ -n "${ORCA_RELAY_BINARY:-}" ]]; then
    source_binary="$ORCA_RELAY_BINARY"
    [[ -x "$source_binary" ]] || die "ORCA_RELAY_BINARY is not executable: $source_binary"
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$source_binary" "$release_dir/orca-relay"
  elif [[ -x "target/x86_64-unknown-linux-musl/release/orca-relay" ]]; then
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "target/x86_64-unknown-linux-musl/release/orca-relay" "$release_dir/orca-relay"
  elif [[ -x "target/release/orca-relay" ]]; then
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "target/release/orca-relay" "$release_dir/orca-relay"
  else
    download_release "$release_dir"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$release_dir"
  fi

  tmp_link="$INSTALL_DIR/current.tmp"
  ln -sfn "$release_dir" "$tmp_link"
  mv -Tf "$tmp_link" "$CURRENT_LINK"
}

write_caddy_config() {
  [[ "$CADDY_MODE" == "managed" ]] || return 0
  [[ -n "$DOMAIN" ]] || die "--domain is required for --caddy-mode managed"
  write_file "$CADDY_SITE" 0644 root:root < <(render_caddy)
  if [[ -f "$CADDYFILE" ]] && ! grep -qF "import /etc/caddy/conf.d/*.caddy" "$CADDYFILE"; then
    cp -a "$CADDYFILE" "$CADDYFILE.orca-relay.bak"
    printf '\nimport /etc/caddy/conf.d/*.caddy\n' >>"$CADDYFILE"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
    systemctl reload caddy || systemctl restart caddy
  elif command -v caddy >/dev/null 2>&1; then
    caddy reload --config "$CADDYFILE" || warn "caddy reload failed; inspect $CADDYFILE and $CADDY_SITE"
  else
    warn "Caddy reload skipped because neither systemctl caddy.service nor caddy CLI is available"
  fi
}

install_service() {
  [[ "$CADDY_MODE" != "managed" || -n "$DOMAIN" ]] || die "--domain is required for --caddy-mode managed"
  if [[ -e "$CURRENT_LINK" && "$FORCE" != "1" && -z "$VERSION" && -z "${ORCA_RELAY_BINARY:-}" ]]; then
    die "existing install found; pass --force, --version, or ORCA_RELAY_BINARY"
  fi
  load_token
  local snapshot
  snapshot="$(snapshot_existing)"
  info "snapshot=$snapshot"
  ensure_user_and_dirs
  install_binary
  write_file "$ENV_FILE" 0640 "root:$SERVICE_USER" < <(render_env "$TOKEN")
  write_file "$UNIT_FILE" 0644 root:root < <(render_unit)
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  write_caddy_config
  if [[ "$CADDY_MODE" == "render-only" ]]; then
    info "# Caddy render-only output for $CADDY_SITE"
    render_caddy
  fi
  info "installed=true"
  info "service=$SERVICE_NAME"
  info "bind=$BIND"
  if [[ -n "$DOMAIN" ]]; then
    info "public_url=wss://$DOMAIN/ws"
  fi
  info "token_file=$ENV_FILE (redacted)"
  info "rollback=sudo $INSTALL_DIR/install-vps.sh rollback"
  install -m 0755 "$0" "$INSTALL_DIR/install-vps.sh" 2>/dev/null || true
}

latest_snapshot() {
  [[ -d "$SNAPSHOT_ROOT" ]] || return 1
  find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-
}

restore_snapshot_file() {
  local snapshot="$1"
  local original="$2"
  local saved="$snapshot/$(echo "$original" | tr '/' '_')"
  if [[ -e "$saved" ]]; then
    install -d -m 0755 "$(dirname "$original")"
    cp -a "$saved" "$original"
  fi
}

rollback_install() {
  local snapshot target
  snapshot="$(latest_snapshot || true)"
  [[ -n "$snapshot" ]] || die "no snapshots found in $SNAPSHOT_ROOT"
  restore_snapshot_file "$snapshot" "$ENV_FILE"
  restore_snapshot_file "$snapshot" "$UNIT_FILE"
  restore_snapshot_file "$snapshot" "$CADDY_SITE"
  restore_snapshot_file "$snapshot" "$CADDYFILE"
  if [[ -f "$snapshot/current-target.txt" ]]; then
    target="$(cat "$snapshot/current-target.txt")"
    if [[ -n "$target" && -e "$target" ]]; then
      ln -sfn "$target" "$INSTALL_DIR/current.tmp"
      mv -Tf "$INSTALL_DIR/current.tmp" "$CURRENT_LINK"
    fi
  fi
  systemctl daemon-reload || true
  systemctl restart "$SERVICE_NAME" || true
  if [[ "$CADDY_MODE" != "skip" ]]; then
    systemctl reload caddy 2>/dev/null || true
  fi
  info "rolled_back_from=$snapshot"
}

uninstall_service() {
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload 2>/dev/null || true
  if [[ "$CADDY_MODE" == "managed" ]]; then
    rm -f "$CADDY_SITE"
    systemctl reload caddy 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR"
  if [[ "$PURGE" == "1" ]]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
  else
    info "kept_config=$CONFIG_DIR"
    info "kept_state=$STATE_DIR"
  fi
  info "uninstalled=true"
}

case "$COMMAND" in
  render)
    print_rendered_files
    ;;
  install)
    require_root
    if [[ "$DRY_RUN" == "1" ]]; then
      print_rendered_files
      info "dry_run=true"
    else
      install_service
    fi
    ;;
  rollback)
    require_root
    if [[ "$DRY_RUN" == "1" ]]; then
      info "dry_run=true"
      info "latest_snapshot=$(latest_snapshot || true)"
    else
      rollback_install
    fi
    ;;
  uninstall)
    require_root
    if [[ "$DRY_RUN" == "1" ]]; then
      info "dry_run=true"
      info "would_stop=$SERVICE_NAME"
      info "would_remove=$INSTALL_DIR"
      [[ "$PURGE" == "1" ]] && info "would_purge=$CONFIG_DIR $STATE_DIR"
    else
      uninstall_service
    fi
    ;;
  *)
    die "unknown command: $COMMAND"
    ;;
esac
