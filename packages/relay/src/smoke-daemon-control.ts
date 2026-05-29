import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { WebSocket } from 'ws';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: { id: string; code: string };
}

interface RelayMessage {
  type: 'message';
  message: {
    payload: {
      type: string;
      requestId?: string;
      ok?: boolean;
      data?: unknown;
    };
  };
}

const baseUrl = process.env.NUDGE_RELAY_SMOKE_URL ?? 'http://127.0.0.1:8787';
const nudgeBin = process.env.NUDGE_SMOKE_NUDGE_BIN ?? join(process.cwd(), '..', '..', 'target', 'debug', 'nudge');

async function main(): Promise<void> {
  const tmp = await mkdtemp(join(tmpdir(), 'nudge-daemon-control-'));
  let daemon: ChildProcess | undefined;
  try {
    const daemonDevice = await registerDevice('daemon', 'smoke-daemon-key');
    const phoneDevice = await registerDevice('phone', 'smoke-phone-key');
    const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemonDevice.id });
    await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phoneDevice.id });
    await postJson('/api/bind/confirm', { bindingId: binding.binding.id, daemonDeviceId: daemonDevice.id });

    const env = {
      ...process.env,
      NUDGE_STATE_PATH: join(tmp, 'state', 'session.json'),
      NUDGE_RUNTIME_DIR: join(tmp, 'run'),
    };
    await runNudge(env, [
      'set-binding-state',
      '--relay-url',
      baseUrl,
      '--daemon-device-id',
      daemonDevice.id,
      '--binding-id',
      binding.binding.id,
      '--code',
      binding.binding.code,
      '--status',
      'active',
      '--bound-phone-id',
      phoneDevice.id,
    ]);

    daemon = spawn(nudgeBin, ['daemon', 'run'], { env, stdio: 'ignore' });
    await waitForDaemonRelay(env);

    const phoneSocket = await connectPhone(phoneDevice.id, binding.binding.id);
    phoneSocket.send(JSON.stringify({
      toDeviceId: daemonDevice.id,
      payload: { type: 'get_state', requestId: 'state-1' },
    }));
    const stateResponse = await waitForDaemonResponse(phoneSocket, 'state-1');
    if (!stateResponse.message.payload.ok) {
      throw new Error(`state response failed: ${JSON.stringify(stateResponse)}`);
    }

    phoneSocket.send(JSON.stringify({
      toDeviceId: daemonDevice.id,
      payload: { type: 'terminal_input', requestId: 'input-1', tabId: 'default', text: 'echo NUDGE_RELAY_CONTROL', enter: true },
    }));
    const inputResponse = await waitForDaemonResponse(phoneSocket, 'input-1');
    if (!inputResponse.message.payload.ok) {
      throw new Error(`input response failed: ${JSON.stringify(inputResponse)}`);
    }

    await sleep(300);
    const output = await runNudge(env, ['pty-output', '--max-bytes', '8192']);
    if (!output.includes('NUDGE_RELAY_CONTROL')) {
      throw new Error(`terminal output did not include relay input marker: ${output}`);
    }

    phoneSocket.close();
    await runNudge(env, ['daemon', 'stop']);
    console.log(`daemon relay control smoke passed binding=${binding.binding.id}`);
  } finally {
    if (daemon && !daemon.killed) {
      daemon.kill('SIGTERM');
    }
    await rm(tmp, { recursive: true, force: true });
  }
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

async function runNudge(env: NodeJS.ProcessEnv, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(nudgeBin, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('exit', (code) => {
      const out = Buffer.concat(stdout).toString('utf8');
      const err = Buffer.concat(stderr).toString('utf8');
      if (code !== 0) {
        reject(new Error(`nudge ${args.join(' ')} failed with ${code}: ${err || out}`));
        return;
      }
      resolve(out);
    });
  });
}

async function waitForDaemonRelay(env: NodeJS.ProcessEnv): Promise<void> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const status = await runNudge(env, ['daemon', 'status']);
      if (status.includes('relay_status=connected')) {
        return;
      }
    } catch {
      // daemon socket may not be ready yet
    }
    await sleep(200);
  }
  throw new Error('daemon did not connect to relay');
}

async function connectPhone(deviceId: string, bindingId: string): Promise<WebSocket> {
  const wsUrl = `${baseUrl.replace(/^http/, 'ws')}/ws/mobile?deviceId=${deviceId}&bindingId=${bindingId}`;
  const websocket = new WebSocket(wsUrl);
  await new Promise<void>((resolve, reject) => {
    websocket.once('open', () => resolve());
    websocket.once('error', reject);
  });
  await waitForMessage(websocket, (message) => message.type === 'connected');
  return websocket;
}

async function waitForDaemonResponse(websocket: WebSocket, requestId: string): Promise<RelayMessage> {
  return waitForMessage(websocket, (message): message is RelayMessage => (
    message.type === 'message' &&
    message.message?.payload?.type === 'daemon_response' &&
    message.message.payload.requestId === requestId
  ));
}

function waitForMessage<T extends Record<string, any>>(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => message is T,
): Promise<T>;
function waitForMessage(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => boolean,
): Promise<Record<string, any>>;
function waitForMessage(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => boolean,
): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      websocket.off('message', onMessage);
      reject(new Error('timed out waiting for websocket message'));
    }, 5000);
    const onMessage = (bytes: Buffer) => {
      const message = JSON.parse(bytes.toString()) as Record<string, any>;
      if (!predicate(message)) {
        return;
      }
      clearTimeout(timeout);
      websocket.off('message', onMessage);
      resolve(message);
    };
    websocket.on('message', onMessage);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
