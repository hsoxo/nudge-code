import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: {
    id: string;
    code: string;
    daemonDeviceId: string;
    phoneDeviceId?: string;
    status: string;
  };
}

const relayBin = join(process.cwd(), 'dist', 'index.js');
const port = Number.parseInt(process.env.NUDGE_RELAY_PERSISTENCE_PORT ?? '8792', 10);
const baseUrl = `http://127.0.0.1:${port}`;

async function main(): Promise<void> {
  const tmp = await mkdtemp(join(tmpdir(), 'nudge-relay-persistence-'));
  const statePath = join(tmp, 'relay-state.json');
  let relay: ChildProcess | undefined;
  try {
    relay = await startRelay(statePath);
    const daemon = await registerDevice('daemon', 'daemon-public-key');
    const phone = await registerDevice('phone', 'phone-public-key');
    const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
    await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phone.id });
    const confirmed = await postJson<BindingResponse>('/api/bind/confirm', {
      bindingId: binding.binding.id,
      daemonDeviceId: daemon.id,
    });
    if (confirmed.binding.status !== 'active') {
      throw new Error(`expected active binding, got ${confirmed.binding.status}`);
    }

    await stopRelay(relay);
    relay = await startRelay(statePath);

    const status = await getJson<BindingResponse>(
      `/api/bind/status?bindingId=${binding.binding.id}&deviceId=${daemon.id}`,
    );
    if (status.binding.status !== 'active' || status.binding.phoneDeviceId !== phone.id) {
      throw new Error(`persisted binding mismatch: ${JSON.stringify(status)}`);
    }
    console.log(`relay persistence smoke passed binding=${binding.binding.id}`);
  } finally {
    if (relay) {
      await stopRelay(relay);
    }
    await rm(tmp, { recursive: true, force: true });
  }
}

async function startRelay(statePath: string): Promise<ChildProcess> {
  const relay = spawn(process.execPath, [relayBin], {
    env: {
      ...process.env,
      NUDGE_RELAY_PORT: String(port),
      NUDGE_RELAY_STATE_PATH: statePath,
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  relay.stderr?.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8');
  });
  relay.on('exit', (code) => {
    if (code !== null && code !== 0) {
      stderr += `relay exited with ${code}`;
    }
  });
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (relay.exitCode !== null) {
      throw new Error(stderr || `relay exited with ${relay.exitCode}`);
    }
    try {
      const health = await getJson<{ ok: boolean }>('/healthz');
      if (health.ok) {
        return relay;
      }
    } catch {
      // relay may still be binding the port
    }
    await sleep(100);
  }
  throw new Error(`relay did not start: ${stderr}`);
}

async function stopRelay(relay: ChildProcess): Promise<void> {
  if (relay.exitCode !== null) {
    return;
  }
  relay.kill('SIGTERM');
  await new Promise<void>((resolve) => {
    relay.once('exit', () => resolve());
    setTimeout(() => {
      if (relay.exitCode === null) {
        relay.kill('SIGKILL');
      }
      resolve();
    }, 2000);
  });
}

async function registerDevice(kind: 'daemon' | 'phone', publicKey: string): Promise<{ id: string }> {
  const response = await postJson<DeviceResponse>('/api/devices/register', { kind, publicKey });
  return response.device;
}

async function postJson<T = unknown>(path: string, body: unknown): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as T;
}

async function getJson<T = unknown>(path: string): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`);
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as T;
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
