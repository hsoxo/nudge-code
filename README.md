# Nudge

Nudge is a Rust-first remote shell workspace for coding-agent sessions. The computer side is a native `nudge` binary with CLI and daemon/server modes; the relay is a Node/TypeScript service; iOS is native and TestFlight-first.

This repository is a monorepo: Rust computer-side crates, the Node/TypeScript relay, the TypeScript protocol mirror, shared protobuf definitions, installer scripts, docs, and the future native iOS app live together so protocol and release changes stay synchronized.

## Phase 0 Commands

```sh
cargo build
cargo run -p nudge-cli -- --help
npm install
npm run build
npm run smoke:persistence --workspace @nudge/relay
NUDGE_INSTALL_DRY_RUN=1 scripts/install.sh
cd apps/mobile-ios && xcodegen generate --spec project.yml
```

## Current Local Daemon Checks

```sh
cargo run -p nudge-cli --
cargo run -p nudge-cli -- daemon status
cargo run -p nudge-cli -- daemon stop
cargo run -p nudge-cli -- service install --dry-run
```
