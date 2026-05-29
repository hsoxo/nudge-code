#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  darwin) TARGET_OS="macos" ;;
  linux) TARGET_OS="linux" ;;
  *) echo "unsupported OS for smoke install" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  arm64|aarch64) TARGET_ARCH="aarch64" ;;
  x86_64|amd64) TARGET_ARCH="x86_64" ;;
  *) echo "unsupported architecture for smoke install" >&2; exit 1 ;;
esac

ARTIFACT="nudge-${TARGET_OS}-${TARGET_ARCH}.tar.gz"
RELEASE_DIR="$TMP_DIR/releases/latest"
INSTALL_DIR="$TMP_DIR/install"
SMOKE_BIN="$TMP_DIR/nudge"

mkdir -p "$RELEASE_DIR"
printf '#!/usr/bin/env sh\necho nudge smoke\n' > "$SMOKE_BIN"
chmod 755 "$SMOKE_BIN"
NUDGE_RELEASE_OUT_DIR="$RELEASE_DIR" \
NUDGE_BINARY="$SMOKE_BIN" \
NUDGE_TARGET_OS="$TARGET_OS" \
NUDGE_TARGET_ARCH="$TARGET_ARCH" \
  "$ROOT_DIR/scripts/package-release.sh" >/dev/null

NUDGE_RELEASE_BASE_URL="$TMP_DIR/releases" \
NUDGE_INSTALL_DIR="$INSTALL_DIR" \
  "$ROOT_DIR/scripts/install.sh"

OUTPUT="$("$INSTALL_DIR/nudge")"
if [ "$OUTPUT" != "nudge smoke" ]; then
  echo "unexpected installed nudge output: $OUTPUT" >&2
  exit 1
fi

echo "install smoke passed"
