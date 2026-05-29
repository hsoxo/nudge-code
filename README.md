# Nudge

Nudge is a Rust-first remote shell workspace for coding-agent sessions. The computer side is a native `nudge` binary with CLI and daemon/server modes; the relay is a Node/TypeScript service; iOS is native and TestFlight-first.

This repository is a monorepo: Rust computer-side crates, the Node/TypeScript relay, the TypeScript protocol mirror, shared protobuf definitions, installer scripts, docs, and the future native iOS app live together so protocol and release changes stay synchronized.

## Phase 0 Commands

```sh
cargo build
cargo run -p nudge-cli -- --help
npm install
npm run build
npm run smoke:audit --workspace @nudge/relay
npm run smoke:auth --workspace @nudge/relay
npm run smoke:daemon-control --workspace @nudge/relay
npm run smoke:e2e --workspace @nudge/relay
npm run smoke:http-disabled --workspace @nudge/relay
npm run smoke:persistence --workspace @nudge/relay
npm run smoke:rate-limit --workspace @nudge/relay
npm run smoke:readyz --workspace @nudge/relay
npm run smoke:ios-launch
scripts/smoke-ios-relay-claim.sh
npm run check:local-first
npm run check:handoff
NUDGE_INSTALL_DRY_RUN=1 scripts/install.sh
NUDGE_VERSION=v0.0.0 NUDGE_BINARY=target/debug/nudge scripts/package-release.sh
NUDGE_VERSION=v0.0.0 scripts/prepare-install-site.sh
scripts/smoke-install.sh
cd apps/mobile-ios && xcodegen generate --spec project.yml
```

For the current local-first target, use [docs/local-first-run.md](/Users/hhe/Projects/code-mule/docs/local-first-run.md). It keeps relay on the development machine and supports either simulator, same-network phone such as `http://10.10.10.xxx:8787`, or a temporary Cloudflare Tunnel URL.

```sh
npm run relay:local
NUDGE_RELAY_URL=http://10.10.10.xxx:8787 npm run bind:local
```

## Current Local Daemon Checks

```sh
cargo run -p nudge-cli --
cargo run -p nudge-cli -- daemon status
cargo run -p nudge-cli -- daemon stop
cargo run -p nudge-cli -- service install --dry-run
cargo run -p nudge-cli -- update --dry-run
cargo run -p nudge-cli -- update --dry-run --require-signature --public-key-url https://nudgecode.dev/releases/nudge-release-public.pem
```
