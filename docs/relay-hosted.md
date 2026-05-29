# Hosted Relay

Nudge's first relay target is a hosted Node/TypeScript service. For a production-like deployment, run the relay with hosted mode enabled:

```sh
NUDGE_RELAY_HOSTED_MODE=1 \
NUDGE_RELAY_STATE_PATH=/var/lib/nudge/relay-state.json \
NUDGE_RELAY_AUDIT_PATH=/var/log/nudge/relay-audit.jsonl \
NUDGE_RELAY_PORT=8787 \
node packages/relay/dist/index.js
```

`NUDGE_RELAY_HOSTED_MODE=1` enables the relay hardening defaults expected for hosted service traffic:

- signed websocket auth is required
- relay-issued one-shot websocket challenges are required
- E2E relay payloads are required
- legacy HTTP message send/poll endpoints are disabled

The hosted preset does not choose storage or proxy settings automatically. Set `NUDGE_RELAY_STATE_PATH` on single-process deployments so device and binding metadata survive restarts. Set `NUDGE_RELAY_TRUST_PROXY=1` only when the relay is behind a trusted reverse proxy that sets `X-Forwarded-For`.

Check readiness after startup:

```sh
curl -fsSL http://127.0.0.1:8787/readyz
```

For a hardened single-process hosted deployment, `warnings` should not include:

- `relay_state_not_persistent`
- `websocket_signature_not_required`
- `websocket_challenge_not_required`
- `legacy_http_messages_enabled`
- `e2e_payload_not_required`

Current limits:

- Local JSON state is suitable for the first single-process hosted MVP, but not for multiple relay instances.
- Pairing challenge and websocket challenge stores are in memory. Multi-instance hosting should move them to Redis or managed storage.
- Queued relay messages are process-local by design so terminal/control payloads are not persisted by default.
