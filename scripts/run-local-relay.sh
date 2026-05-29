#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PORT="${NUDGE_RELAY_PORT:-8787}"
HOST="${NUDGE_RELAY_HOST:-0.0.0.0}"
ADVERTISED_URL="${NUDGE_RELAY_URL:-}"
STATE_PATH="${NUDGE_RELAY_STATE_PATH:-$ROOT_DIR/.nudge-local/relay-state.json}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

detect_lan_ips() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show scope global 2>/dev/null \
      | awk '/inet / { sub("/.*", "", $2); print $2 }'
    return
  fi

  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null \
      | awk '/inet / { print $2 }' \
      | grep -Ev '^(127\.|169\.254\.)' || true
  fi
}

require_command npm

if [ ! -f "$ROOT_DIR/packages/relay/dist/index.js" ]; then
  (cd "$ROOT_DIR" && npm run build --workspace @nudge/relay)
fi

mkdir -p "$(dirname "$STATE_PATH")"

echo "nudge local relay"
echo "listen=$HOST:$PORT"
echo "simulator_url=http://127.0.0.1:$PORT"
if [ -n "$ADVERTISED_URL" ]; then
  echo "advertised_url=$ADVERTISED_URL"
fi

LAN_IPS="$(detect_lan_ips | sort -u || true)"
if [ -n "$LAN_IPS" ]; then
  for ip in $LAN_IPS; do
    echo "lan_url=http://$ip:$PORT"
  done
else
  echo "lan_url=http://<computer-lan-ip>:$PORT"
fi

echo "bind_example=target/debug/nudge bind phone --relay-url http://<computer-lan-ip>:$PORT --wait"
echo "cloudflare_tunnel=cloudflared tunnel --url http://127.0.0.1:$PORT"

cd "$ROOT_DIR"
NUDGE_RELAY_HOST="$HOST" \
NUDGE_RELAY_PORT="$PORT" \
NUDGE_RELAY_URL="$ADVERTISED_URL" \
NUDGE_RELAY_STATE_PATH="$STATE_PATH" \
NUDGE_RELAY_REQUIRE_WS_SIGNATURE="${NUDGE_RELAY_REQUIRE_WS_SIGNATURE:-1}" \
NUDGE_RELAY_REQUIRE_WS_CHALLENGE="${NUDGE_RELAY_REQUIRE_WS_CHALLENGE:-1}" \
NUDGE_RELAY_REQUIRE_E2E_PAYLOAD="${NUDGE_RELAY_REQUIRE_E2E_PAYLOAD:-1}" \
NUDGE_RELAY_DISABLE_HTTP_MESSAGES="${NUDGE_RELAY_DISABLE_HTTP_MESSAGES:-1}" \
npm --workspace @nudge/relay run start
