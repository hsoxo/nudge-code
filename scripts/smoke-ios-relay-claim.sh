#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nudge-ios-relay-claim.XXXXXX")"
RELAY_PID=""
BIND_PID=""
LOG_DIR="$TMP_DIR/logs"
STATE_PATH="$TMP_DIR/state/session.json"
RUNTIME_DIR="$TMP_DIR/run"
RELAY_PORT="${NUDGE_IOS_SMOKE_RELAY_PORT:-}"
DESTINATION="${NUDGE_IOS_SMOKE_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
BIND_TIMEOUT_SECONDS="${NUDGE_IOS_SMOKE_BIND_TIMEOUT_SECONDS:-240}"
XCODE_PROJECT="$ROOT_DIR/apps/mobile-ios/NudgeMobile.xcodeproj"
NUDGE_BIN="${NUDGE_SMOKE_NUDGE_BIN:-$ROOT_DIR/target/debug/nudge}"
RELAY_BIN="$ROOT_DIR/packages/relay/dist/index.js"
PAIRING_FILE="$TMP_DIR/pairing.txt"
BIND_LOG="$LOG_DIR/bind.log"
RELAY_LOG="$LOG_DIR/relay.log"
PHONE_SIGNING_KEY_BASE64="BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="
SIMULATOR_UDID="${NUDGE_IOS_SMOKE_SIMULATOR_UDID:-}"

cleanup() {
  set +e
  if [ -n "$BIND_PID" ]; then
    kill "$BIND_PID" >/dev/null 2>&1 || true
    wait "$BIND_PID" >/dev/null 2>&1 || true
  fi
  NUDGE_STATE_PATH="$STATE_PATH" NUDGE_RUNTIME_DIR="$RUNTIME_DIR" "$NUDGE_BIN" daemon stop >/dev/null 2>&1 || true
  if [ -n "$RELAY_PID" ]; then
    kill "$RELAY_PID" >/dev/null 2>&1 || true
    wait "$RELAY_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$SIMULATOR_UDID" ]; then
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl unsetenv NUDGE_IOS_INTEGRATION >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl unsetenv NUDGE_IOS_RELAY_URL >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl unsetenv NUDGE_IOS_PAIRING_CODE >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl unsetenv NUDGE_IOS_PHONE_PUBLIC_KEY >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl unsetenv NUDGE_IOS_PHONE_SIGNING_KEY_BASE64 >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

require_file() {
  if [ ! -f "$1" ]; then
    echo "required file not found: $1" >&2
    exit 1
  fi
}

if [ ! -f "$NUDGE_BIN" ] && [ -z "${NUDGE_SMOKE_NUDGE_BIN:-}" ]; then
  cargo build -p nudge-cli >/dev/null
fi
require_file "$NUDGE_BIN"
require_file "$RELAY_BIN"

if [ -z "$SIMULATOR_UDID" ]; then
  SIMULATOR_NAME="$(
    printf '%s\n' "$DESTINATION" | sed -n 's/.*name=\([^,]*\).*/\1/p'
  )"
  if [ -z "$SIMULATOR_NAME" ]; then
    echo "set NUDGE_IOS_SMOKE_SIMULATOR_UDID when NUDGE_IOS_SMOKE_DESTINATION does not include name=..." >&2
    exit 1
  fi
  SIMULATOR_UDID="$(
    python3 - "$SIMULATOR_NAME" <<'PY'
import json
import subprocess
import sys

name = sys.argv[1]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtimes in devices.get("devices", {}).values():
    for device in runtimes:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
PY
  )" || {
    echo "unable to find available simulator named $SIMULATOR_NAME" >&2
    exit 1
  }
fi

xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null
XCODE_DESTINATION="id=$SIMULATOR_UDID"

if [ -z "$RELAY_PORT" ]; then
  RELAY_PORT="$(
    python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
  )"
fi
RELAY_URL="http://127.0.0.1:$RELAY_PORT"

mkdir -p "$LOG_DIR" "$(dirname "$STATE_PATH")" "$RUNTIME_DIR"

NUDGE_RELAY_PORT="$RELAY_PORT" \
NUDGE_RELAY_STATE_PATH="$TMP_DIR/relay-state.json" \
NUDGE_RELAY_REQUIRE_E2E_PAYLOAD=1 \
NUDGE_RELAY_REQUIRE_WS_SIGNATURE=1 \
NUDGE_RELAY_REQUIRE_WS_CHALLENGE=1 \
NUDGE_RELAY_DISABLE_HTTP_MESSAGES=1 \
node "$RELAY_BIN" >"$RELAY_LOG" 2>&1 &
RELAY_PID="$!"

for _ in $(seq 1 80); do
  if curl -fsSL "$RELAY_URL/healthz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$RELAY_PID" >/dev/null 2>&1; then
    cat "$RELAY_LOG" >&2
    echo "relay exited before becoming healthy" >&2
    exit 1
  fi
  sleep 0.1
done
curl -fsSL "$RELAY_URL/healthz" >/dev/null

NUDGE_STATE_PATH="$STATE_PATH" \
NUDGE_RUNTIME_DIR="$RUNTIME_DIR" \
"$NUDGE_BIN" bind phone \
  --relay-url "$RELAY_URL" \
  --wait \
  --yes \
  --timeout-seconds "$BIND_TIMEOUT_SECONDS" >"$BIND_LOG" 2>&1 &
BIND_PID="$!"

PAIRING_URL=""
for _ in $(seq 1 100); do
  if grep -Eo 'https?://[^ ]+/pair\?code=[^ ]+' "$BIND_LOG" >"$PAIRING_FILE" 2>/dev/null; then
    PAIRING_URL="$(tail -n 1 "$PAIRING_FILE")"
    break
  fi
  if ! kill -0 "$BIND_PID" >/dev/null 2>&1; then
    cat "$BIND_LOG" >&2
    echo "bind command exited before printing a pairing URL" >&2
    exit 1
  fi
  sleep 0.1
done

if [ -z "$PAIRING_URL" ]; then
  cat "$BIND_LOG" >&2
  echo "timed out waiting for pairing URL" >&2
  exit 1
fi
PAIRING_CODE="${PAIRING_URL##*code=}"

xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv NUDGE_IOS_INTEGRATION 1
xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv NUDGE_IOS_RELAY_URL "$RELAY_URL"
xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv NUDGE_IOS_PAIRING_CODE "$PAIRING_CODE"
xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv NUDGE_IOS_PHONE_SIGNING_KEY_BASE64 "$PHONE_SIGNING_KEY_BASE64"

(
  cd "$ROOT_DIR/apps/mobile-ios"
  NUDGE_IOS_INTEGRATION=1 \
  NUDGE_IOS_RELAY_URL="$RELAY_URL" \
  NUDGE_IOS_PAIRING_CODE="$PAIRING_CODE" \
  NUDGE_IOS_PHONE_SIGNING_KEY_BASE64="$PHONE_SIGNING_KEY_BASE64" \
  xcodebuild test \
    -project "$XCODE_PROJECT" \
    -scheme NudgeMobile \
    -destination "$XCODE_DESTINATION" \
    -only-testing:NudgeMobileTests/RelayClientTests
)

wait "$BIND_PID"
BIND_PID=""

if ! grep -q "binding active" "$BIND_LOG"; then
  cat "$BIND_LOG" >&2
  echo "bind command did not confirm the iOS claim" >&2
  exit 1
fi

echo "iOS relay claim smoke passed relay=$RELAY_URL"
