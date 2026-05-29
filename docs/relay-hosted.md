# Hosted Relay

Nudge's first relay target is a hosted Node/TypeScript service. For a production-like deployment, run the relay with hosted mode enabled:

```sh
NUDGE_RELAY_HOSTED_MODE=1 \
NUDGE_RELAY_DATABASE_URL=postgres://nudge:secret@postgres:5432/nudge \
NUDGE_RELAY_AUDIT_PATH=/var/log/nudge/relay-audit.jsonl \
NUDGE_RELAY_PORT=8787 \
node packages/relay/dist/index.js
```

The repo also includes a production container build for hosts that deploy Node services as containers:

```sh
docker build -f packages/relay/Dockerfile -t nudge-relay .
docker run --rm -p 8787:8787 \
  -e NUDGE_RELAY_DATABASE_URL=postgres://nudge:secret@postgres:5432/nudge \
  -e NUDGE_RELAY_AUDIT_PATH=/var/log/nudge/relay-audit.jsonl \
  -v nudge-relay-logs:/var/log/nudge \
  nudge-relay
```

The container enables `NUDGE_RELAY_HOSTED_MODE=1` by default.

The release workflow builds this image on Linux, smoke-checks `/readyz`, and publishes tagged releases to GitHub Container Registry:

```sh
docker pull ghcr.io/<owner>/nudge-relay:<version>
```

Use the tag-specific image for deployments. The workflow also updates `latest` for convenience, but release tags are the safer deployment reference.

`NUDGE_RELAY_HOSTED_MODE=1` enables the relay hardening defaults expected for hosted service traffic:

- signed websocket auth is required
- relay-issued one-shot websocket challenges are required
- E2E relay payloads are required
- legacy HTTP message send/poll endpoints are disabled

The hosted preset does not choose storage or proxy settings automatically. Prefer `NUDGE_RELAY_DATABASE_URL` for hosted deployments; the relay creates a `relay_state` table and stores device/binding metadata as a JSONB state document. `NUDGE_RELAY_STATE_PATH` remains available for local single-process deployments and smoke tests. Do not set both; `NUDGE_RELAY_DATABASE_URL` wins when both are present. Set `NUDGE_RELAY_TRUST_PROXY=1` only when the relay is behind a trusted reverse proxy that sets `X-Forwarded-For`.

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

- Postgres state storage is suitable for a single hosted relay instance with managed backups, but it still writes the relay metadata state as one JSONB document. It is not yet a multi-writer, horizontally scalable state model.
- Local JSON state is suitable for local single-process MVP testing, but not for hosted production or multiple relay instances.
- Pairing challenge and websocket challenge stores are in memory. Multi-instance hosting should move them to Redis or managed storage.
- Queued relay messages are process-local by design so terminal/control payloads are not persisted by default.
