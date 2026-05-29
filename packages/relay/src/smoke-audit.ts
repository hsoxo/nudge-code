import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
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
const port = Number.parseInt(process.env.NUDGE_RELAY_AUDIT_PORT ?? '8794', 10);
const baseUrl = `http://127.0.0.1:${port}`;
const terminalSecret = 'SECRET_TERMINAL_PAYLOAD_SHOULD_NOT_BE_LOGGED';
const publicKeySecret = 'daemon-public-key-should-not-be-logged';

async function main(): Promise<void> {
  const tmp = await mkdtemp(join(tmpdir(), 'nudge-relay-audit-'));
  const auditPath = join(tmp, 'relay-audit.jsonl');
  let relay: ChildProcess | undefined;
  try {
    relay = await startRelay(auditPath);
    const daemon = await registerDevice('daemon', publicKeySecret);
    const phone = await registerDevice('phone', 'phone-public-key');
    const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
    await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phone.id });
    await postJson('/api/bind/confirm', { bindingId: binding.binding.id, daemonDeviceId: daemon.id });
    await postJson('/api/messages/send', {
      bindingId: binding.binding.id,
      fromDeviceId: phone.id,
      toDeviceId: daemon.id,
      payload: { type: 'terminal_input', text: terminalSecret, enter: true },
    });

    const auditText = await readFile(auditPath, 'utf8');
    assertContains(auditText, '"type":"device_registered"');
    assertContains(auditText, '"type":"binding_started"');
    assertContains(auditText, '"type":"binding_claimed"');
    assertContains(auditText, '"type":"binding_confirmed"');
    assertContains(auditText, '"type":"message_queued"');
    assertContains(auditText, '"payloadType":"terminal_input"');
    assertNotContains(auditText, terminalSecret);
    assertNotContains(auditText, binding.binding.code);
    assertNotContains(auditText, publicKeySecret);

    console.log('relay audit smoke passed');
  } finally {
    if (relay) {
      await stopRelay(relay);
    }
    await rm(tmp, { recursive: true, force: true });
  }
}

async function startRelay(auditPath: string): Promise<ChildProcess> {
  const relay = spawn(process.execPath, [relayBin], {
    env: {
      ...process.env,
      NUDGE_RELAY_PORT: String(port),
      NUDGE_RELAY_AUDIT_PATH: auditPath,
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

function assertContains(value: string, expected: string): void {
  if (!value.includes(expected)) {
    throw new Error(`expected audit log to contain ${expected}, got ${value}`);
  }
}

function assertNotContains(value: string, unexpected: string): void {
  if (value.includes(unexpected)) {
    throw new Error(`audit log leaked ${unexpected}: ${value}`);
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
