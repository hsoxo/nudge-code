#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XTERM_DIR="$ROOT_DIR/node_modules/@xterm/xterm"
DEST_DIR="$ROOT_DIR/apps/mobile-ios/NudgeMobile/Resources/TerminalWeb"

if [[ ! -f "$XTERM_DIR/lib/xterm.js" || ! -f "$XTERM_DIR/css/xterm.css" ]]; then
  echo "@xterm/xterm is required. Run npm install first." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$XTERM_DIR/lib/xterm.js" "$DEST_DIR/xterm.js"
cp "$XTERM_DIR/css/xterm.css" "$DEST_DIR/xterm.css"
cp "$XTERM_DIR/LICENSE" "$DEST_DIR/XTERM_LICENSE"
