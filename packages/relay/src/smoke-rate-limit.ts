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
const port = Number.parseInt(process.env.NUDGE_RELAY_RATE_LIMIT_PORT ?? '8793', 10);
const baseUrl = `http://127.0.0.1:${port}`;

async function main(): Promise<void> {
  let relay: ChildProcess | undefined;
  try {
    relay = await startRelay();
    const daemon = await registerDevice('daemon', 'daemon-public-key');
    const phone = await registerDevice('phone', 'phone-public-key');
    const firstBinding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
    const invalidCode = `${firstBinding.binding.code}X`;

    await expectClaimStatus(invalidCode, phone.id, 404, 'pairing_code_not_found');
    await expectClaimStatus(invalidCode, phone.id, 404, 'pairing_code_not_found');
    await expectClaimStatus(invalidCode, phone.id, 429, 'pairing_rate_limited');

    const secondBinding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
    const claimed = await postJson<BindingResponse>('/api/bind/claim', {
      code: secondBinding.binding.code,
      phoneDeviceId: phone.id,
    });
    if (claimed.binding.status !== 'claimed') {
      throw new Error(`expected second binding to be claimed, got ${claimed.binding.status}`);
    }

    console.log('relay pairing rate limit smoke passed');
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
      NUDGE_PAIRING_CLAIM_CODE_LIMIT: '2',
      NUDGE_PAIRING_CLAIM_IP_LIMIT: '100',
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

async function expectClaimStatus(
  code: string,
  phoneDeviceId: string,
  status: number,
  error: string,
): Promise<void> {
  const response = await fetch(`${baseUrl}/api/bind/claim`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code, phoneDeviceId }),
  });
  const payload = (await response.json()) as { error?: string };
  if (response.status !== status || payload.error !== error) {
    throw new Error(`expected claim ${status}/${error}, got ${response.status}/${JSON.stringify(payload)}`);
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
