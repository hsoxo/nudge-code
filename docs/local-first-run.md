# Local First Run

This is the first-version path before TestFlight, hosted relay deployment, or `nudgecode.dev` install hosting. The relay runs on the development computer; the computer CLI/daemon and the iOS simulator or phone connect to that relay.

## Simulator Smoke

Run the automated local integration first:

```sh
npm install
npm run build
cargo build -p nudge-cli
scripts/smoke-ios-relay-claim.sh
```

The smoke starts an isolated local relay, starts `nudge bind phone --wait --yes`, claims the pairing from the iOS simulator test process, opens the native relay session, verifies tab state/output replay, sends terminal input, and verifies live daemon output.

## Development Relay

For manual testing, run the relay on the development machine:

```sh
npm run relay:local
```

The script prints usable relay URLs. Use `http://127.0.0.1:8787` from the simulator. Use `http://<computer-lan-ip>:8787` from a physical phone on the same network. For a `10.10.10.xxx` network, the relay URL will look like `http://10.10.10.42:8787`. The iOS app allows local-network HTTP for this development path.

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
cargo build -p nudge-cli
target/debug/nudge bind phone --relay-url <relay-url> --wait
```

On the iOS simulator or phone:

1. Open Nudge.
2. Open Bind.
3. Scan the QR code or paste the printed `app_pairing_url=nudge://pair?...`.
4. Tap Claim And Wait.
5. Confirm the binding in the computer CLI.
6. Open the machine in the app and verify tab list, terminal output, shortcut keyboard, and command input.

## Current Boundary

This path intentionally does not require TestFlight, EC2, a permanent relay, or `nudgecode.dev` static hosting. It is enough for local product validation of the daemon, relay, iOS shell, pairing, reconnect, terminal rendering, and phone-to-shell input.
