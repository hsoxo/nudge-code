#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XTERM_DIR="$ROOT_DIR/node_modules/@xterm/xterm"
FIT_DIR="$ROOT_DIR/node_modules/@xterm/addon-fit"
WEBGL_DIR="$ROOT_DIR/node_modules/@xterm/addon-webgl"
UNICODE11_DIR="$ROOT_DIR/node_modules/@xterm/addon-unicode11"
DEST_DIR="$ROOT_DIR/apps/mobile-ios/NudgeMobile/Resources/TerminalWeb"

if [[ ! -f "$XTERM_DIR/lib/xterm.js" || ! -f "$XTERM_DIR/css/xterm.css" ]]; then
  echo "@xterm/xterm is required. Run npm install first." >&2
  exit 1
fi

if [[ ! -f "$FIT_DIR/lib/addon-fit.js" || ! -f "$WEBGL_DIR/lib/addon-webgl.js" || ! -f "$UNICODE11_DIR/lib/addon-unicode11.js" ]]; then
  echo "@xterm/addon-fit, @xterm/addon-webgl, and @xterm/addon-unicode11 are required. Run npm install first." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$XTERM_DIR/lib/xterm.js" "$DEST_DIR/xterm.js"
cp "$XTERM_DIR/css/xterm.css" "$DEST_DIR/xterm.css"
cp "$XTERM_DIR/LICENSE" "$DEST_DIR/XTERM_LICENSE"
cp "$FIT_DIR/lib/addon-fit.js" "$DEST_DIR/addon-fit.js"
cp "$WEBGL_DIR/lib/addon-webgl.js" "$DEST_DIR/addon-webgl.js"
cp "$UNICODE11_DIR/lib/addon-unicode11.js" "$DEST_DIR/addon-unicode11.js"
