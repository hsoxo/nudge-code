#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PORT="${NUDGE_RELAY_PORT:-8787}"
RELAY_URL="${NUDGE_RELAY_URL:-}"
NUDGE_BIN="${NUDGE_BIN:-$ROOT_DIR/target/debug/nudge}"
DRY_RUN="${NUDGE_BIND_LOCAL_DRY_RUN:-0}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

if [ "${1:-}" != "" ]; then
  case "$1" in
    http://*|https://*)
      RELAY_URL="$1"
      shift
      ;;
  esac
fi

if [ -z "$RELAY_URL" ]; then
  if [ "${NUDGE_LAN_IP:-}" != "" ]; then
    RELAY_URL="http://$NUDGE_LAN_IP:$PORT"
  else
    RELAY_URL="http://127.0.0.1:$PORT"
  fi
fi

case "$RELAY_URL" in
  http://*|https://*) ;;
  *)
    echo "relay URL must start with http:// or https://: $RELAY_URL" >&2
    exit 1
    ;;
esac

echo "nudge local bind"
echo "relay_url=$RELAY_URL"

if [ "$DRY_RUN" = "1" ]; then
  echo "command=NUDGE_RELAY_URL=$RELAY_URL $NUDGE_BIN bind phone --wait $*"
  exit 0
fi

if [ ! -f "$NUDGE_BIN" ]; then
  require_command cargo
  (cd "$ROOT_DIR" && cargo build -p nudge-cli >/dev/null)
fi

if command -v curl >/dev/null 2>&1; then
  if ! curl -fsSL "$RELAY_URL/healthz" >/dev/null 2>&1; then
    echo "relay is not reachable at $RELAY_URL/healthz" >&2
    echo "start it with: npm run relay:local" >&2
    exit 1
  fi
fi

echo "waiting for phone claim; paste or scan the app_pairing_url printed below"
export NUDGE_RELAY_URL="$RELAY_URL"
# Local/dev daemon runs as paid so the multi-tab new-tab flow is usable
# (the relay still issues FREE; the daemon override keeps it paid). Override
# by exporting NUDGE_DAEMON_PLAN before invoking this script.
export NUDGE_DAEMON_PLAN="${NUDGE_DAEMON_PLAN:-pro}"
exec "$NUDGE_BIN" bind phone --wait "$@"
