import { spawn, type ChildProcess } from 'node:child_process';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: { id: string; code: string; status: string };
}

const relayBin = join(process.cwd(), 'dist', 'index.js');
const port = Number.parseInt(process.env.NUDGE_RELAY_FREE_ENTITLEMENT_PORT ?? '8794', 10);
const baseUrl = `http://127.0.0.1:${port}`;

async function main(): Promise<void> {
  let relay: ChildProcess | undefined;
  try {
    relay = await startRelay();
    const firstDaemon = await registerDevice('daemon', 'daemon-public-key-1');
    const secondDaemon = await registerDevice('daemon', 'daemon-public-key-2');
    const phone = await registerDevice('phone', 'phone-public-key');

    const firstBinding = await postJson<BindingResponse>('/api/bind/start', {
      daemonDeviceId: firstDaemon.id,
    });
    const firstClaim = await postJson<BindingResponse>('/api/bind/claim', {
      code: firstBinding.binding.code,
      phoneDeviceId: phone.id,
    });
    if (firstClaim.binding.status !== 'claimed') {
      throw new Error(`expected first binding to be claimed, got ${firstClaim.binding.status}`);
    }

    const secondBinding = await postJson<BindingResponse>('/api/bind/start', {
      daemonDeviceId: secondDaemon.id,
    });
    await expectPostError(
      '/api/bind/claim',
      { code: secondBinding.binding.code, phoneDeviceId: phone.id },
      409,
      'free_entitlement_computer_limit',
    );

    await postJson('/api/bind/revoke', {
      bindingId: firstBinding.binding.id,
      deviceId: firstDaemon.id,
    });

    const secondClaim = await postJson<BindingResponse>('/api/bind/claim', {
      code: secondBinding.binding.code,
      phoneDeviceId: phone.id,
    });
    if (secondClaim.binding.status !== 'claimed') {
      throw new Error(`expected second binding to be claimed after revoke, got ${secondClaim.binding.status}`);
    }

    console.log('relay free entitlement smoke passed');
  } finally {
    if (relay) {
      await stopRelay(relay);
    }
  }
}

async function startRelay(): Promise<ChildProcess> {
  const relay = spawn(process.execPath, [relayBin], {
    env: {
      ...process.env,
      NUDGE_RELAY_PORT: String(port),
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

async function expectPostError(path: string, body: unknown, status: number, error: string): Promise<void> {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const payload = (await response.json()) as { error?: string };
  if (response.status !== status || payload.error !== error) {
    throw new Error(`expected ${path} ${status}/${error}, got ${response.status}/${JSON.stringify(payload)}`);
  }
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
