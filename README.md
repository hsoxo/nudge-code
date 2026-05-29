# Nudge

Nudge is a Rust-first remote shell workspace for coding-agent sessions. The computer side is a native `nudge` binary with CLI and daemon/server modes; the relay is a Node/TypeScript service; iOS is native and TestFlight-first.

## Phase 0 Commands

```sh
cargo build
cargo run -p nudge-cli -- --help
cargo run -p nudge-cli -- daemon --placeholder
npm install
npm run build
NUDGE_INSTALL_DRY_RUN=1 scripts/install.sh
```
