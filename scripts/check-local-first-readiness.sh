#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

require_file() {
  if [ ! -f "$1" ]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

require_executable() {
  require_file "$1"
  if [ ! -x "$1" ]; then
    echo "script is not executable: $1" >&2
    exit 1
  fi
}

require_pattern() {
  file="$1"
  pattern="$2"
  if ! grep -F "$pattern" "$file" >/dev/null 2>&1; then
    echo "missing pattern in $file: $pattern" >&2
    exit 1
  fi
}

LOCAL_DOC="$ROOT_DIR/docs/local-first-run.md"
IOS_PLIST="$ROOT_DIR/apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/Info.plist"
IOS_PROJECT_SPEC="$ROOT_DIR/apps/mobile-ios/project.yml"
RELAY_SRC="$ROOT_DIR/packages/relay/src/index.ts"
PACKAGE_JSON="$ROOT_DIR/package.json"

require_file "$LOCAL_DOC"
require_file "$IOS_PLIST"
require_file "$IOS_PROJECT_SPEC"
require_file "$RELAY_SRC"
require_file "$PACKAGE_JSON"
require_executable "$ROOT_DIR/scripts/run-local-bind.sh"
require_executable "$ROOT_DIR/scripts/run-local-relay.sh"
require_executable "$ROOT_DIR/scripts/smoke-ios-launch.sh"
require_executable "$ROOT_DIR/scripts/smoke-ios-relay-claim.sh"

require_pattern "$LOCAL_DOC" "npm run smoke:ios-launch"
require_pattern "$LOCAL_DOC" "scripts/smoke-ios-relay-claim.sh"
require_pattern "$LOCAL_DOC" "npm run relay:local"
require_pattern "$LOCAL_DOC" "npm run bind:local"
require_pattern "$LOCAL_DOC" "NUDGE_RELAY_URL"
require_pattern "$LOCAL_DOC" "iPhone 13"
require_pattern "$LOCAL_DOC" "iOS 17.0 or newer"
require_pattern "$LOCAL_DOC" "http://<computer-lan-ip>:8787"
require_pattern "$LOCAL_DOC" "http://10.10.10.42:8787"
require_pattern "$LOCAL_DOC" "cloudflared tunnel --url http://127.0.0.1:8787"
require_pattern "$IOS_PLIST" "<key>NSAllowsLocalNetworking</key>"
require_pattern "$IOS_PLIST" "<key>NSLocalNetworkUsageDescription</key>"
require_pattern "$IOS_PROJECT_SPEC" "NSAllowsLocalNetworking: true"
require_pattern "$IOS_PROJECT_SPEC" "NSLocalNetworkUsageDescription"
require_pattern "$RELAY_SRC" "process.env.NUDGE_RELAY_HOST ?? '0.0.0.0'"
require_pattern "$RELAY_SRC" "process.env.NUDGE_RELAY_URL"
require_pattern "$PACKAGE_JSON" "\"bind:local\""
require_pattern "$PACKAGE_JSON" "\"relay:local\""
require_pattern "$PACKAGE_JSON" "\"smoke:ios-launch\""

NUDGE_BIND_LOCAL_DRY_RUN=1 \
NUDGE_RELAY_URL=http://10.10.10.42:8787 \
"$ROOT_DIR/scripts/run-local-bind.sh" --yes >/dev/null

echo "local-first readiness check passed"
