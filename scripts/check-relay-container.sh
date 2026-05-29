#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DOCKERFILE="$ROOT_DIR/packages/relay/Dockerfile"

if [ ! -f "$DOCKERFILE" ]; then
  echo "missing relay Dockerfile: $DOCKERFILE" >&2
  exit 1
fi

for path in \
  "$ROOT_DIR/package.json" \
  "$ROOT_DIR/package-lock.json" \
  "$ROOT_DIR/packages/protocol-ts/package.json" \
  "$ROOT_DIR/packages/protocol-ts/tsconfig.json" \
  "$ROOT_DIR/packages/protocol-ts/src/index.ts" \
  "$ROOT_DIR/packages/relay/package.json" \
  "$ROOT_DIR/packages/relay/tsconfig.json" \
  "$ROOT_DIR/packages/relay/src/index.ts"
do
  if [ ! -e "$path" ]; then
    echo "relay container input is missing: $path" >&2
    exit 1
  fi
done

for pattern in \
  "FROM node:24-alpine AS deps" \
  "RUN npm ci" \
  "RUN npm run build --workspaces --if-present" \
  "RUN npm prune --omit=dev" \
  "NUDGE_RELAY_HOSTED_MODE=1" \
  "EXPOSE 8787" \
  'CMD ["node", "packages/relay/dist/index.js"]'
do
  if ! grep -F "$pattern" "$DOCKERFILE" >/dev/null 2>&1; then
    echo "relay Dockerfile is missing expected pattern: $pattern" >&2
    exit 1
  fi
done

echo "relay container definition check passed"
