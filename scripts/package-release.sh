#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${NUDGE_VERSION:-latest}"
OUT_DIR="${NUDGE_RELEASE_OUT_DIR:-$ROOT_DIR/dist/releases/$VERSION}"
BINARY="${NUDGE_BINARY:-$ROOT_DIR/target/release/nudge}"
SIGNING_KEY="${NUDGE_SIGNING_KEY:-}"

case "${NUDGE_TARGET_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}" in
  darwin|macos) TARGET_OS="macos" ;;
  linux) TARGET_OS="linux" ;;
  *) echo "unsupported OS: ${NUDGE_TARGET_OS:-$(uname -s)}" >&2; exit 1 ;;
esac

case "${NUDGE_TARGET_ARCH:-$(uname -m)}" in
  arm64|aarch64) TARGET_ARCH="aarch64" ;;
  x86_64|amd64) TARGET_ARCH="x86_64" ;;
  *) echo "unsupported architecture: ${NUDGE_TARGET_ARCH:-$(uname -m)}" >&2; exit 1 ;;
esac

if [ ! -f "$BINARY" ]; then
  echo "nudge binary not found: $BINARY" >&2
  echo "run: cargo build --release -p nudge-cli" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nudge-release.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

ARTIFACT="nudge-${TARGET_OS}-${TARGET_ARCH}.tar.gz"
mkdir -p "$OUT_DIR" "$TMP_DIR/artifact"
cp "$BINARY" "$TMP_DIR/artifact/nudge"
chmod 755 "$TMP_DIR/artifact/nudge"
(cd "$TMP_DIR/artifact" && tar -czf "$OUT_DIR/$ARTIFACT" nudge)

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && sha256sum "$ARTIFACT" | awk '{print $1 "  " $2}' > "$ARTIFACT.sha256")
elif command -v shasum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && shasum -a 256 "$ARTIFACT" | awk '{print $1 "  " $2}' > "$ARTIFACT.sha256")
else
  echo "sha256sum or shasum is required to write checksum" >&2
  exit 1
fi

echo "artifact=$OUT_DIR/$ARTIFACT"
echo "checksum=$OUT_DIR/$ARTIFACT.sha256"

if [ -n "$SIGNING_KEY" ]; then
  if [ ! -f "$SIGNING_KEY" ]; then
    echo "signing key not found: $SIGNING_KEY" >&2
    exit 1
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to sign release artifacts" >&2
    exit 1
  fi
  openssl dgst -sha256 -sign "$SIGNING_KEY" -out "$OUT_DIR/$ARTIFACT.sig" "$OUT_DIR/$ARTIFACT"
  echo "signature=$OUT_DIR/$ARTIFACT.sig"
fi
