import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRelayStateStore, normalizeRelayState, type PersistedRelayState } from './state-store.js';

async function main(): Promise<void> {
  const legacyState = normalizeRelayState({
    version: 1,
    devices: [{
      id: 'phone_legacy',
      kind: 'phone',
      publicKey: 'phone-public-key',
      createdAt: new Date(0).toISOString(),
    }],
    bindings: [{
      id: 'bind_legacy',
      code: 'ABC123',
      daemonDeviceId: 'daemon_legacy',
      phoneDeviceId: 'phone_legacy',
      status: 'active',
      createdAt: new Date(0).toISOString(),
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      confirmedAt: new Date(0).toISOString(),
    }],
    updatedAt: new Date(0).toISOString(),
  }, 'legacy smoke state');
  if (legacyState.devices[0]?.status !== 'active') {
    throw new Error(`expected legacy device status to default active: ${JSON.stringify(legacyState)}`);
  }

  const tmp = await mkdtemp(join(tmpdir(), 'nudge-relay-state-store-'));
  try {
    const statePath = join(tmp, 'relay-state.json');
    const store = createRelayStateStore({ statePath });
    const state: PersistedRelayState = {
      version: 1,
      devices: [{
        id: 'daemon_1',
        kind: 'daemon',
        publicKey: 'daemon-public-key',
        createdAt: new Date(0).toISOString(),
        status: 'active',
      }],
      bindings: [],
      updatedAt: new Date(0).toISOString(),
    };
    await store.save(state);
    const restored = await store.load();
    if (restored?.devices[0]?.id !== 'daemon_1' || restored.devices[0]?.status !== 'active') {
      throw new Error(`state store roundtrip mismatch: ${JSON.stringify(restored)}`);
    }
    const raw = await readFile(statePath, 'utf8');
    if (raw.includes('terminal_input') || raw.includes('payload')) {
      throw new Error(`relay state unexpectedly stored terminal payload fields: ${raw}`);
    }
    console.log('relay state store smoke passed');
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
