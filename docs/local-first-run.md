# Local First Run

This is the first-version path before TestFlight, hosted relay deployment, or `nudgecode.dev` install hosting. The relay runs on the development computer; the computer CLI/daemon and the iOS simulator or phone connect to that relay.

## Simulator Smoke

Run the automated local integration first:

```sh
npm install
npm run build
cargo build -p nudge-cli
npm run smoke:ios-launch
scripts/smoke-ios-relay-claim.sh
```

The smoke starts an isolated local relay, starts `nudge bind phone --wait --yes`, claims the pairing from the iOS simulator test process, opens the native relay session, verifies tab state/output replay, sends terminal input, and verifies live daemon output.

`npm run smoke:ios-launch` builds, installs, and launches the native app on an available iPhone simulator, then treats an immediate app exit as a launch crash. Run it before hand-testing if you are validating an app crash report.

Last validated: 2026-05-30 on the iPhone 17 simulator (iOS 26.1), branch `fix/bind-validation-quickwins`. Both smokes passed, the bind reached `binding active`, and the relay audit log showed the full E2E round-trip (signed-WS challenge handshake plus ephemeral routed payloads). See `docs/HANDOVER.md` -> `Simulator Validation (2026-05-30)` for the command list and per-checklist coverage.

## Device Compatibility

The current native app targets iOS 17.0 or newer and portrait-only iPhone. An iPhone 13 is compatible when it is running iOS 17.0 or newer. iOS 16 and older are not supported by the current first-version app because the SwiftUI/Observation stack is built for the iOS 17 target.

For a physical iPhone 13 local run, keep the phone and computer on the same Wi-Fi, use the computer's `10.10.10.xxx` relay URL during binding, and accept the Local Network and Camera permission prompts.

## Development Relay

For manual testing, run the relay on the development machine:

```sh
npm run relay:local
```

The script prints usable relay URLs. Use `http://127.0.0.1:8787` from the simulator. Use `http://<computer-lan-ip>:8787` from a physical phone on the same network. For a `10.10.10.xxx` network, the relay URL will look like `http://10.10.10.42:8787`. The iOS app allows local-network HTTP for this development path.

`NUDGE_RELAY_URL` is the canonical relay URL for the packaged CLI and relay. Set it when the advertised URL differs from localhost, such as a LAN IP or Cloudflare Tunnel URL.

To override the port:

```sh
NUDGE_RELAY_PORT=8790 npm run relay:local
```

## Cloudflare Tunnel Option

If the phone cannot reach the development computer directly, keep the same local relay running and expose it with a temporary tunnel:

```sh
cloudflared tunnel --url http://127.0.0.1:8787
```

Use the printed `https://...trycloudflare.com` URL as the relay URL for binding. Cloudflare quick tunnels are temporary; restart the bind flow when the URL changes.

## Bind Flow

In another terminal, build the computer binary and start binding:

```sh
npm run bind:local
```

By default this uses `http://127.0.0.1:8787`, which is correct for simulator testing. For a physical phone on your `10.10.10.xxx` network, use the LAN URL printed by `npm run relay:local`:

```sh
NUDGE_RELAY_URL=http://10.10.10.xxx:8787 npm run bind:local
```

You can also pass the relay URL as the first argument:

```sh
npm run bind:local -- http://10.10.10.xxx:8787
```

For a Cloudflare quick tunnel, use the printed HTTPS URL:

```sh
NUDGE_RELAY_URL=https://example.trycloudflare.com npm run bind:local
```

The bind helper checks `<relay-url>/healthz`, starts `target/debug/nudge bind phone --wait`, and prints the `app_pairing_url=nudge://pair?...` that the app can open directly.

On the iOS simulator or phone:

1. Open Nudge.
2. Open Bind.
3. Scan the QR code or paste the printed `app_pairing_url=nudge://pair?...`.
4. Tap Claim And Wait.
5. Confirm the binding in the computer CLI.
6. Open the machine in the app and verify tab list, terminal output, shortcut keyboard, command input, and tab actions.

For the free first-version entitlement, one computer and one tab are allowed. Rename and restart should work on the default tab, closing the only tab is disabled in the native UI, and creating a second tab is expected to be rejected until a higher tab entitlement is available.

## Current Boundary

This path intentionally does not require TestFlight, EC2, a permanent relay, or `nudgecode.dev` static hosting. It is enough for local product validation of the daemon, relay, iOS shell, pairing, reconnect, terminal rendering, and phone-to-shell input.
