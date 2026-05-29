#!/usr/bin/env sh
set -eu

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
VERSION="${NUDGE_VERSION:-latest}"
INSTALL_DIR="${NUDGE_INSTALL_DIR:-$HOME/.local/bin}"
BASE_URL="${NUDGE_RELEASE_BASE_URL:-https://nudgecode.dev/releases}"

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

if [ "${NUDGE_INSTALL_DRY_RUN:-0}" = "1" ]; then
  echo "nudge install dry run"
  echo "target=${TARGET_OS}-${TARGET_ARCH}"
  echo "install_dir=${INSTALL_DIR}"
  echo "url=${URL}"
  exit 0
fi

echo "This Phase 0 installer skeleton only supports dry run."
echo "Run with NUDGE_INSTALL_DRY_RUN=1 to verify platform detection."
exit 2
