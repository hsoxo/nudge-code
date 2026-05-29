#!/usr/bin/env sh
set -eu

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
VERSION="${NUDGE_VERSION:-latest}"
INSTALL_DIR="${NUDGE_INSTALL_DIR:-$HOME/.local/bin}"
BASE_URL="${NUDGE_RELEASE_BASE_URL:-https://nudgecode.dev/releases}"

download() {
  from="$1"
  to="$2"
  case "$from" in
    file://*) cp "${from#file://}" "$to" ;;
    /*|./*|../*) cp "$from" "$to" ;;
    *)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$from" -o "$to"
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "$to" "$from"
      else
        echo "curl or wget is required to download $from" >&2
        exit 1
      fi
      ;;
  esac
}

verify_checksum() {
  archive="$1"
  checksum_file="$2"
  expected="$(awk '{print $1}' "$checksum_file")"
  if [ -z "$expected" ]; then
    echo "checksum file is empty: $checksum_file" >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  else
    echo "sha256sum or shasum is required to verify $archive" >&2
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $archive" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

case "$OS" in
  darwin) TARGET_OS="macos" ;;
  linux) TARGET_OS="linux" ;;
  *) echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

case "$ARCH" in
  arm64|aarch64) TARGET_ARCH="aarch64" ;;
  x86_64|amd64) TARGET_ARCH="x86_64" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

ARTIFACT="nudge-${TARGET_OS}-${TARGET_ARCH}.tar.gz"
URL="${BASE_URL}/${VERSION}/${ARTIFACT}"
CHECKSUM_URL="${URL}.sha256"

if [ "${NUDGE_INSTALL_DRY_RUN:-0}" = "1" ]; then
  echo "nudge install dry run"
  echo "target=${TARGET_OS}-${TARGET_ARCH}"
  echo "install_dir=${INSTALL_DIR}"
  echo "url=${URL}"
  echo "checksum_url=${CHECKSUM_URL}"
  exit 0
fi

cleanup() {
  rm -rf "$TMP_DIR"
}
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nudge-install.XXXXXX")"
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"
ARCHIVE="$TMP_DIR/$ARTIFACT"

download "$URL" "$ARCHIVE"

if [ "${NUDGE_SKIP_CHECKSUM:-0}" != "1" ]; then
  CHECKSUM_FILE="$TMP_DIR/$ARTIFACT.sha256"
  download "$CHECKSUM_URL" "$CHECKSUM_FILE"
  verify_checksum "$ARCHIVE" "$CHECKSUM_FILE"
fi

tar -xzf "$ARCHIVE" -C "$TMP_DIR"
if [ -f "$TMP_DIR/nudge" ]; then
  BINARY="$TMP_DIR/nudge"
else
  BINARY="$(find "$TMP_DIR" -type f -name nudge 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${BINARY:-}" ] || [ ! -f "$BINARY" ]; then
  echo "artifact did not contain executable nudge binary" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_DIR/nudge"
chmod 755 "$INSTALL_DIR/nudge"

echo "installed nudge to $INSTALL_DIR/nudge"
if ! command -v nudge >/dev/null 2>&1; then
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) echo "add $INSTALL_DIR to PATH to run nudge directly" ;;
  esac
fi
