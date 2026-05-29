#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

require_file() {
  if [ ! -f "$1" ]; then
    echo "missing required file: $1" >&2
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

require_executable() {
  file="$1"
  require_file "$file"
  if [ ! -x "$file" ]; then
    echo "script is not executable: $file" >&2
    exit 1
  fi
}

IOS_PLIST="$ROOT_DIR/apps/mobile-ios/NudgeMobile/Sources/NudgeMobile/Info.plist"
IOS_PROJECT_SPEC="$ROOT_DIR/apps/mobile-ios/project.yml"
IOS_README="$ROOT_DIR/apps/mobile-ios/README.md"
RELAY_DOC="$ROOT_DIR/docs/relay-hosted.md"
INSTALL_DOC="$ROOT_DIR/docs/install.md"
IMPLEMENTATION_PLAN="$ROOT_DIR/IMPLEMENTATION_PLAN.md"

for file in \
  "$IOS_PLIST" \
  "$IOS_PROJECT_SPEC" \
  "$IOS_README" \
  "$RELAY_DOC" \
  "$INSTALL_DOC" \
  "$IMPLEMENTATION_PLAN" \
  "$ROOT_DIR/packages/relay/Dockerfile" \
  "$ROOT_DIR/packages/relay/package.json" \
  "$ROOT_DIR/package.json"
do
  require_file "$file"
done

for script in \
  "$ROOT_DIR/scripts/install.sh" \
  "$ROOT_DIR/scripts/package-release.sh" \
  "$ROOT_DIR/scripts/prepare-install-site.sh" \
  "$ROOT_DIR/scripts/smoke-install.sh" \
  "$ROOT_DIR/scripts/smoke-ios-relay-claim.sh"
do
  require_executable "$script"
done

require_pattern "$IOS_PLIST" "<string>nudge</string>"
require_pattern "$IOS_PLIST" "<string>UIInterfaceOrientationPortrait</string>"
require_pattern "$IOS_PLIST" "<key>NSCameraUsageDescription</key>"
require_pattern "$IOS_PROJECT_SPEC" "CFBundleURLSchemes:"
require_pattern "$IOS_PROJECT_SPEC" "UIInterfaceOrientationPortrait"
require_pattern "$IOS_README" "TestFlight-only first"
require_pattern "$IOS_README" "nudge://pair"
require_pattern "$IOS_README" "smoke-ios-relay-claim.sh"

for asset in \
  "$ROOT_DIR/apps/mobile-ios/NudgeMobile/Resources/TerminalWeb/index.html" \
  "$ROOT_DIR/apps/mobile-ios/NudgeMobile/Resources/TerminalWeb/xterm.js" \
  "$ROOT_DIR/apps/mobile-ios/NudgeMobile/Resources/TerminalWeb/xterm.css"
do
  require_file "$asset"
done

require_pattern "$RELAY_DOC" "NUDGE_RELAY_HOSTED_MODE=1"
require_pattern "$RELAY_DOC" "NUDGE_RELAY_DATABASE_URL"
require_pattern "$RELAY_DOC" "/readyz"
require_pattern "$RELAY_DOC" "ghcr.io/<owner>/nudge-relay:<version>"
require_pattern "$INSTALL_DOC" "curl -fsSL https://nudgecode.dev/install.sh | sh"
require_pattern "$INSTALL_DOC" "nudge-install-site.tar.gz"

"$ROOT_DIR/scripts/check-relay-container.sh" >/dev/null

echo "handoff readiness check passed"
