#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/apps/mobile-ios/Generated"
PROTO_FILE="$ROOT_DIR/proto/nudge.proto"

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc is required to generate Swift protocol types" >&2
  exit 1
fi

if ! command -v protoc-gen-swift >/dev/null 2>&1; then
  echo "protoc-gen-swift is required to generate Swift protocol types" >&2
  echo "Install it with: brew install swift-protobuf" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
protoc \
  --proto_path="$ROOT_DIR/proto" \
  --swift_out="$OUT_DIR" \
  "$PROTO_FILE"
