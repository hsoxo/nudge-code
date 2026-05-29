#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nudge-ios-launch.XXXXXX")"
LOG_DIR="$TMP_DIR/logs"
DERIVED_DATA="$TMP_DIR/DerivedData"
PROJECT="$ROOT_DIR/apps/mobile-ios/NudgeMobile.xcodeproj"
SCHEME="${NUDGE_IOS_LAUNCH_SCHEME:-NudgeMobile}"
BUNDLE_ID="${NUDGE_IOS_LAUNCH_BUNDLE_ID:-dev.nudgecode.NudgeMobile}"
SIMULATOR_UDID="${NUDGE_IOS_LAUNCH_SIMULATOR_UDID:-}"
WAIT_SECONDS="${NUDGE_IOS_LAUNCH_WAIT_SECONDS:-3}"
KEEP_LOGS="${NUDGE_IOS_LAUNCH_KEEP_LOGS:-0}"
BUILD_LOG="$LOG_DIR/build.log"
APP_STDOUT_LOG="$LOG_DIR/app.stdout.log"
APP_STDERR_LOG="$LOG_DIR/app.stderr.log"

print_logs() {
  echo "launch smoke log dir: $LOG_DIR" >&2
  for log in "$BUILD_LOG" "$APP_STDOUT_LOG" "$APP_STDERR_LOG"; do
    if [ -f "$log" ]; then
      echo "--- $(basename "$log") ---" >&2
      cat "$log" >&2
    fi
  done
}

cleanup() {
  set +e
  if [ "$KEEP_LOGS" = "1" ]; then
    echo "kept launch smoke logs at $TMP_DIR" >&2
  else
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM
trap 'print_logs' ERR

select_simulator() {
  python3 <<'PY'
import json
import os
import subprocess
import sys

preferred_name = os.environ.get("NUDGE_IOS_LAUNCH_SIMULATOR_NAME", "")
preferred_order = {
    "iPhone 17": 0,
    "iPhone 17 Pro": 1,
    "iPhone 16e": 2,
}
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
candidates = []
for runtime_devices in devices.get("devices", {}).values():
    for device in runtime_devices:
        name = device.get("name", "")
        if "iPhone" not in name:
            continue
        if preferred_name and name != preferred_name:
            continue
        state = device.get("state", "")
        state_rank = 0 if state == "Booted" else 1
        name_rank = preferred_order.get(name, 50)
        candidates.append((state_rank, name_rank, name, device["udid"], state))

if not candidates:
    target = preferred_name or "any available iPhone simulator"
    print(f"unable to find {target}", file=sys.stderr)
    raise SystemExit(1)

candidates.sort()
_, _, name, udid, state = candidates[0]
print(f"{udid}\t{name}\t{state}")
PY
}

mkdir -p "$LOG_DIR"

if [ -z "$SIMULATOR_UDID" ]; then
  SELECTED_SIMULATOR="$(select_simulator)"
  SIMULATOR_UDID="$(printf '%s' "$SELECTED_SIMULATOR" | cut -f1)"
  SIMULATOR_NAME="$(printf '%s' "$SELECTED_SIMULATOR" | cut -f2)"
else
  SIMULATOR_NAME="$SIMULATOR_UDID"
fi

echo "nudge iOS launch smoke"
echo "simulator=$SIMULATOR_NAME"
echo "udid=$SIMULATOR_UDID"

xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null

xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "id=$SIMULATOR_UDID" \
  -derivedDataPath "$DERIVED_DATA" >"$BUILD_LOG" 2>&1

APP_PATH="$(
  find "$DERIVED_DATA/Build/Products/Debug-iphonesimulator" \
    -name "NudgeMobile.app" \
    -type d \
    -print \
    -quit
)"
if [ -z "$APP_PATH" ]; then
  echo "unable to find built NudgeMobile.app under $DERIVED_DATA" >&2
  exit 1
fi

xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

LAUNCH_OUTPUT="$(
  xcrun simctl launch \
    --terminate-running-process \
    --stdout="$APP_STDOUT_LOG" \
    --stderr="$APP_STDERR_LOG" \
    "$SIMULATOR_UDID" \
    "$BUNDLE_ID"
)"
echo "$LAUNCH_OUTPUT"

sleep "$WAIT_SECONDS"

if ! xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "NudgeMobile was not running after ${WAIT_SECONDS}s; treating this as a launch crash" >&2
  exit 1
fi

echo "iOS launch smoke passed"
