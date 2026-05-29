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
SIGNED_INSTALL_DIR="$TMP_DIR/signed-install"
SIGNED_URL_INSTALL_DIR="$TMP_DIR/signed-url-install"
TAMPERED_INSTALL_DIR="$TMP_DIR/tampered-install"
SMOKE_BIN="$TMP_DIR/nudge"
SIGNING_KEY="$TMP_DIR/signing-key.pem"
PUBLIC_KEY="$TMP_DIR/signing-public.pem"

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

if command -v openssl >/dev/null 2>&1; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$SIGNING_KEY" >/dev/null 2>&1
  openssl rsa -pubout -in "$SIGNING_KEY" -out "$PUBLIC_KEY" >/dev/null 2>&1
  rm -rf "$RELEASE_DIR"
  mkdir -p "$RELEASE_DIR"
  NUDGE_RELEASE_OUT_DIR="$RELEASE_DIR" \
  NUDGE_BINARY="$SMOKE_BIN" \
  NUDGE_TARGET_OS="$TARGET_OS" \
  NUDGE_TARGET_ARCH="$TARGET_ARCH" \
  NUDGE_SIGNING_KEY="$SIGNING_KEY" \
    "$ROOT_DIR/scripts/package-release.sh" >/dev/null

  NUDGE_RELEASE_BASE_URL="$TMP_DIR/releases" \
  NUDGE_INSTALL_DIR="$SIGNED_INSTALL_DIR" \
  NUDGE_PUBLIC_KEY_FILE="$PUBLIC_KEY" \
  NUDGE_REQUIRE_SIGNATURE=1 \
    "$ROOT_DIR/scripts/install.sh" >/dev/null

  SIGNED_OUTPUT="$("$SIGNED_INSTALL_DIR/nudge")"
  if [ "$SIGNED_OUTPUT" != "nudge smoke" ]; then
    echo "unexpected signed installed nudge output: $SIGNED_OUTPUT" >&2
    exit 1
  fi

  NUDGE_RELEASE_BASE_URL="$TMP_DIR/releases" \
  NUDGE_INSTALL_DIR="$SIGNED_URL_INSTALL_DIR" \
  NUDGE_PUBLIC_KEY_URL="file://$PUBLIC_KEY" \
  NUDGE_REQUIRE_SIGNATURE=1 \
    "$ROOT_DIR/scripts/install.sh" >/dev/null

  SIGNED_URL_OUTPUT="$("$SIGNED_URL_INSTALL_DIR/nudge")"
  if [ "$SIGNED_URL_OUTPUT" != "nudge smoke" ]; then
    echo "unexpected signed URL-key installed nudge output: $SIGNED_URL_OUTPUT" >&2
    exit 1
  fi

  printf 'tamper' >> "$RELEASE_DIR/$ARTIFACT"
  if NUDGE_RELEASE_BASE_URL="$TMP_DIR/releases" \
    NUDGE_INSTALL_DIR="$TAMPERED_INSTALL_DIR" \
    NUDGE_PUBLIC_KEY_FILE="$PUBLIC_KEY" \
    NUDGE_REQUIRE_SIGNATURE=1 \
    NUDGE_SKIP_CHECKSUM=1 \
    "$ROOT_DIR/scripts/install.sh" >/dev/null 2>&1; then
    echo "tampered signed artifact unexpectedly installed" >&2
    exit 1
  fi
else
  echo "openssl not found; skipping signed install smoke"
fi

echo "install smoke passed"
