#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"
DEFAULT_TARGET="x86_64-unknown-linux-musl"
BINARIES=(orca-relay orca-relay-proxy orca-relay-bridge)
DOCS=(README.md README.zh-CN.md)

usage() {
  cat <<USAGE
Usage:
  scripts/package-release.sh [VERSION] [TARGET]

Package already-built Orca Relay release binaries into a GitHub Release asset.
This script never builds; run the release build before invoking it.

Arguments:
  VERSION  Release version without or with a leading "v". Defaults to Cargo.toml.
  TARGET   Rust target triple. Defaults to ${DEFAULT_TARGET}.

Output:
  dist/orca-relay-v<VERSION>-<TARGET>.tar.gz
  dist/orca-relay-v<VERSION>-<TARGET>.tar.gz.sha256
USAGE
}

die() {
  echo "error: $*" >&2
  exit 2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
  */*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;;
  *) SCRIPT_DIR="." ;;
esac
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

read_manifest_version() {
  local cargo_toml="$REPO_ROOT/Cargo.toml"
  local in_package=0
  local line=""
  local trimmed=""
  local key=""
  local value=""

  [[ -f "$cargo_toml" ]] || die "Cargo.toml not found at $cargo_toml"

  while IFS= read -r line; do
    trimmed="$(trim "$line")"

    case "$trimmed" in
      '[package]')
        in_package=1
        continue
        ;;
      '['*)
        if [[ "$in_package" -eq 1 ]]; then
          break
        fi
        ;;
    esac

    if [[ "$in_package" -eq 1 && "$trimmed" == *=* ]]; then
      key="$(trim "${trimmed%%=*}")"
      if [[ "$key" != "version" ]]; then
        continue
      fi

      value="${trimmed#*=}"
      value="${value%%#*}"
      value="$(trim "$value")"
      value="${value#\"}"
      value="${value%\"}"

      [[ -n "$value" ]] || die "empty package.version in Cargo.toml"
      printf '%s\n' "$value"
      return 0
    fi
  done < "$cargo_toml"

  die "package.version not found in Cargo.toml"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -le 2 ]] || die "too many arguments; expected [VERSION] [TARGET]"

VERSION="${1:-}"
TARGET="${2:-$DEFAULT_TARGET}"

if [[ -z "$VERSION" ]]; then
  VERSION="$(read_manifest_version)"
fi
VERSION="${VERSION#v}"

[[ -n "$VERSION" ]] || die "version must not be empty"
[[ -n "$TARGET" ]] || die "target must not be empty"

case "$VERSION" in
  *[!A-Za-z0-9._+-]*) die "version contains unsupported characters: $VERSION" ;;
esac
case "$TARGET" in
  .|..) die "target must be a target triple, not '$TARGET'" ;;
  *[!A-Za-z0-9._+-]*) die "target contains unsupported characters: $TARGET" ;;
esac

RELEASE_DIR="$REPO_ROOT/target/$TARGET/release"
DIST_DIR="$REPO_ROOT/dist"
ASSET_NAME="orca-relay-v${VERSION}-${TARGET}"
ARCHIVE="$DIST_DIR/${ASSET_NAME}.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
STAGING_ROOT=""

cleanup() {
  if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

[[ -d "$RELEASE_DIR" ]] || die "release directory not found: $RELEASE_DIR"

for binary in "${BINARIES[@]}"; do
  binary_path="$RELEASE_DIR/$binary"
  [[ -f "$binary_path" ]] || die "missing built binary: $binary_path"
  [[ -x "$binary_path" ]] || die "built binary is not executable: $binary_path"
done

for doc in "${DOCS[@]}"; do
  [[ -f "$REPO_ROOT/$doc" ]] || die "missing package document: $doc"
done

mkdir -p "$DIST_DIR"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orca-relay-package.XXXXXX")"
STAGING_DIR="$STAGING_ROOT/$ASSET_NAME"
mkdir -p "$STAGING_DIR"

for binary in "${BINARIES[@]}"; do
  cp -p "$RELEASE_DIR/$binary" "$STAGING_DIR/$binary"
done

for doc in "${DOCS[@]}"; do
  cp -p "$REPO_ROOT/$doc" "$STAGING_DIR/$doc"
done

tar -C "$STAGING_DIR" -czf "$ARCHIVE" "${BINARIES[@]}" "${DOCS[@]}"

(
  cd "$DIST_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${ASSET_NAME}.tar.gz" > "${ASSET_NAME}.tar.gz.sha256"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${ASSET_NAME}.tar.gz" > "${ASSET_NAME}.tar.gz.sha256"
  else
    die "sha256sum or shasum is required to write $CHECKSUM"
  fi
)

printf 'archive: %s\n' "${ARCHIVE#$REPO_ROOT/}"
printf 'checksum: %s\n' "${CHECKSUM#$REPO_ROOT/}"
