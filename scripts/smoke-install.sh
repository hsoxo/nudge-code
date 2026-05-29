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
ARTIFACT_DIR="$TMP_DIR/artifact"
INSTALL_DIR="$TMP_DIR/install"

mkdir -p "$RELEASE_DIR" "$ARTIFACT_DIR"
printf '#!/usr/bin/env sh\necho nudge smoke\n' > "$ARTIFACT_DIR/nudge"
chmod 755 "$ARTIFACT_DIR/nudge"
(cd "$ARTIFACT_DIR" && tar -czf "$RELEASE_DIR/$ARTIFACT" nudge)

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$RELEASE_DIR/$ARTIFACT" | awk '{print $1 "  '"$ARTIFACT"'"}' > "$RELEASE_DIR/$ARTIFACT.sha256"
else
  shasum -a 256 "$RELEASE_DIR/$ARTIFACT" | awk '{print $1 "  '"$ARTIFACT"'"}' > "$RELEASE_DIR/$ARTIFACT.sha256"
fi

NUDGE_RELEASE_BASE_URL="$TMP_DIR/releases" \
NUDGE_INSTALL_DIR="$INSTALL_DIR" \
  "$ROOT_DIR/scripts/install.sh"

OUTPUT="$("$INSTALL_DIR/nudge")"
if [ "$OUTPUT" != "nudge smoke" ]; then
  echo "unexpected installed nudge output: $OUTPUT" >&2
  exit 1
fi

echo "install smoke passed"
