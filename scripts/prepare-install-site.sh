#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${NUDGE_VERSION:-latest}"
RELEASE_DIR="${NUDGE_RELEASE_DIR:-$ROOT_DIR/dist/releases/$VERSION}"
SITE_DIR="${NUDGE_INSTALL_SITE_DIR:-$ROOT_DIR/dist/install-site}"
COPY_LATEST="${NUDGE_INSTALL_SITE_COPY_LATEST:-1}"
PUBLIC_KEY="${NUDGE_RELEASE_PUBLIC_KEY:-}"
PUBLIC_KEY_FILE="${NUDGE_RELEASE_PUBLIC_KEY_FILE:-}"
REQUIRE_PUBLIC_KEY="${NUDGE_REQUIRE_PUBLIC_KEY:-0}"

if [ ! -d "$RELEASE_DIR" ]; then
  echo "release directory not found: $RELEASE_DIR" >&2
  exit 1
fi

mkdir -p "$SITE_DIR/releases/$VERSION"
cp "$ROOT_DIR/scripts/install.sh" "$SITE_DIR/install.sh"
chmod 755 "$SITE_DIR/install.sh"

found_artifact=0
found_signature=0
for artifact in "$RELEASE_DIR"/nudge-*.tar.gz; do
  [ -f "$artifact" ] || continue
  found_artifact=1
  name="$(basename "$artifact")"
  cp "$artifact" "$SITE_DIR/releases/$VERSION/$name"
  if [ -f "$artifact.sha256" ]; then
    cp "$artifact.sha256" "$SITE_DIR/releases/$VERSION/$name.sha256"
  else
    echo "checksum not found for release artifact: $artifact.sha256" >&2
    exit 1
  fi
  if [ -f "$artifact.sig" ]; then
    found_signature=1
    cp "$artifact.sig" "$SITE_DIR/releases/$VERSION/$name.sig"
  fi
done

if [ "$found_artifact" != "1" ]; then
  echo "no nudge release artifacts found in $RELEASE_DIR" >&2
  exit 1
fi

if [ "$COPY_LATEST" = "1" ] && [ "$VERSION" != "latest" ]; then
  rm -rf "$SITE_DIR/releases/latest"
  mkdir -p "$SITE_DIR/releases/latest"
  cp "$SITE_DIR/releases/$VERSION"/nudge-*.tar.gz* "$SITE_DIR/releases/latest/"
fi

PUBLIC_KEY_DEST="$SITE_DIR/releases/nudge-release-public.pem"
if [ -n "$PUBLIC_KEY_FILE" ]; then
  cp "$PUBLIC_KEY_FILE" "$PUBLIC_KEY_DEST"
elif [ -n "$PUBLIC_KEY" ]; then
  printf '%s\n' "$PUBLIC_KEY" > "$PUBLIC_KEY_DEST"
elif [ "$found_signature" = "1" ]; then
  if [ "$REQUIRE_PUBLIC_KEY" = "1" ]; then
    echo "signed release artifacts require NUDGE_RELEASE_PUBLIC_KEY or NUDGE_RELEASE_PUBLIC_KEY_FILE" >&2
    exit 1
  fi
  echo "warning: signed release artifacts found but no public key was published" >&2
fi

echo "install_script=$SITE_DIR/install.sh"
echo "release_dir=$SITE_DIR/releases/$VERSION"
if [ -f "$PUBLIC_KEY_DEST" ]; then
  echo "public_key=$PUBLIC_KEY_DEST"
fi
