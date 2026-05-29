# Deployment And Device-Test Handoff

This is the preflight path before moving from local simulator work to hosted relay deployment and physical iPhone testing.

## Local Handoff Checks

Run these from the repo root:

```sh
npm install
npm run build
cargo test
xcodebuild -project apps/mobile-ios/NudgeMobile.xcodeproj -scheme NudgeMobile -destination 'platform=iOS Simulator,name=iPhone 17' test
scripts/smoke-ios-relay-claim.sh
npm run check:handoff
```

`npm run check:handoff` is a fast static gate. It verifies the iOS app has the `nudge://pair` URL scheme, portrait-only configuration, camera usage text, bundled terminal web assets, hosted relay deployment docs, installer docs, and executable smoke/install scripts. It also runs the relay container definition check.

## Hosted Relay Inputs

Before physical-device testing, choose a public relay URL and deploy one hosted relay instance with:

- `NUDGE_RELAY_HOSTED_MODE=1`
- `NUDGE_RELAY_DATABASE_URL=postgres://...`
- `NUDGE_RELAY_AUDIT_PATH=/var/log/nudge/relay-audit.jsonl`
- TLS termination in front of the relay
- `NUDGE_RELAY_TRUST_PROXY=1` only when the TLS/proxy layer is trusted

After deploy, verify:

```sh
curl -fsSL https://<relay-host>/readyz
```

For the first hosted test, `warnings` should not include weak hosted settings such as missing persistence, missing websocket challenge enforcement, legacy HTTP messages, or non-required E2E payloads.

## Computer Install Inputs

For manual host testing before `nudgecode.dev` static hosting is live:

```sh
cargo build -p nudge-cli
target/debug/nudge service install --dry-run
target/debug/nudge bind phone --relay-url https://<relay-host> --wait
```

Once release hosting is live, use:

```sh
curl -fsSL https://nudgecode.dev/install.sh | sh
nudge service install
nudge bind phone --relay-url https://<relay-host> --wait
```

## iPhone Test Inputs

The iOS app is TestFlight-first and portrait-only for the MVP. Before a real TestFlight upload, configure the Apple team and signing profile in Xcode or CI. The current local project uses bundle id `dev.nudgecode.NudgeMobile`.

Physical-device smoke:

1. Install the iOS app on the phone.
2. Run `nudge bind phone --relay-url https://<relay-host> --wait` on the computer.
3. Scan the QR code or open the printed `app_pairing_url=nudge://pair?...` link on the phone.
4. Confirm the binding in the computer CLI.
5. Verify the phone sees the machine, tab list, terminal output, and agent status.
6. Send shell input from the phone and verify the computer tab receives it.
7. Switch between phone and computer width modes.
8. Background and foreground the app; verify the relay session reconnects.
9. Revoke the binding from the phone and verify the computer loses relay access.

## Open Before Broader Beta

- Publish the static install bundle at `https://nudgecode.dev`.
- Decide the initial hosted relay platform and backup policy.
- Add a physical-device smoke result against the hosted relay.
- Add real Claude/Codex screen captures to the classifier fixture set.
