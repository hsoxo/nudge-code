import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { spawn, type ChildProcess } from 'node:child_process';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { WebSocket } from 'ws';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: { id: string; code: string };
}

interface ChallengeResponse {
  challenge: { id: string; message: string };
}

const relayBin = join(process.cwd(), 'dist', 'index.js');
const port = Number.parseInt(process.env.NUDGE_RELAY_E2E_PORT ?? '8795', 10);
const baseUrl = `http://127.0.0.1:${port}`;

async function main(): Promise<void> {
  let relay: ChildProcess | undefined;
  try {
    relay = await startRelay();
    const daemonIdentity = generateSmokeIdentity();
    const phoneIdentity = generateSmokeIdentity();
    const daemon = await registerDevice('daemon', daemonIdentity.publicKey);
    const phone = await registerDevice('phone', phoneIdentity.publicKey);
    const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
    await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phone.id });
    await postJson('/api/bind/confirm', { bindingId: binding.binding.id, daemonDeviceId: daemon.id });

    await expectPostJson('/api/messages/send', {
      bindingId: binding.binding.id,
      fromDeviceId: phone.id,
      toDeviceId: daemon.id,
      payload: { type: 'terminal_input', text: 'plaintext should be rejected' },
    }, 400, 'e2e_payload_required');

    await postJson('/api/messages/send', {
      bindingId: binding.binding.id,
      fromDeviceId: phone.id,
      toDeviceId: daemon.id,
      payload: encryptedPayload('terminal_input'),
    });
    const polled = await getJson<{ messages: Array<{ payload: { type?: string; ciphertextBase64?: string } }> }>(
      `/api/messages/poll?deviceId=${encodeURIComponent(daemon.id)}`,
    );
    if (polled.messages[0]?.payload.type !== 'e2e_envelope') {
      throw new Error(`expected queued e2e envelope, got ${JSON.stringify(polled)}`);
    }

    const daemonSocket = await connectSocket('daemon', daemon.id, binding.binding.id, daemonIdentity.privateKey);
    const phoneSocket = await connectSocket('mobile', phone.id, binding.binding.id, phoneIdentity.privateKey);
    const rejected = waitForMessage(phoneSocket, (message) => message.type === 'error');
    phoneSocket.send(JSON.stringify({
      toDeviceId: daemon.id,
      payload: { type: 'get_state', requestId: 'plaintext-websocket' },
    }));
    const rejection = await rejected;
    if (rejection.error !== 'e2e_payload_required') {
      throw new Error(`expected e2e_payload_required websocket error, got ${JSON.stringify(rejection)}`);
    }

    const routed = waitForMessage(daemonSocket, (message) => message.type === 'message');
    phoneSocket.send(JSON.stringify({
      toDeviceId: daemon.id,
      payload: encryptedPayload('get_state'),
    }));
    const routedMessage = await routed;
    if (routedMessage.message?.payload?.type !== 'e2e_envelope') {
      throw new Error(`expected routed e2e envelope, got ${JSON.stringify(routedMessage)}`);
    }

    daemonSocket.close();
    phoneSocket.close();
    console.log('relay e2e enforcement smoke passed');
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
      NUDGE_RELAY_REQUIRE_E2E_PAYLOAD: '1',
      NUDGE_RELAY_REQUIRE_WS_SIGNATURE: '1',
      NUDGE_RELAY_REQUIRE_WS_CHALLENGE: '1',
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

async function expectPostJson(path: string, body: unknown, status: number, error: string): Promise<void> {
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

async function getJson<T = unknown>(path: string): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`);
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as T;
}

function encryptedPayload(messageType: string): Record<string, unknown> {
  return {
    type: 'e2e_envelope',
    version: 1,
    messageType,
    senderKeyId: 'phone-key-1',
    recipientKeyId: 'daemon-key-1',
    nonceBase64: Buffer.from('nonce-000001').toString('base64'),
    ciphertextBase64: Buffer.from('opaque ciphertext bytes').toString('base64'),
  };
}

function generateSmokeIdentity(): { publicKey: string; privateKey: KeyObject } {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return {
    publicKey: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64'),
    privateKey,
  };
}

async function connectSocket(
  kind: 'daemon' | 'mobile',
  deviceId: string,
  bindingId: string,
  privateKey: KeyObject,
): Promise<WebSocket> {
  const wsUrl = await signedWebSocketUrl(kind, deviceId, bindingId, privateKey);
  const websocket = new WebSocket(wsUrl);
  await new Promise<void>((resolve, reject) => {
    websocket.once('open', () => resolve());
    websocket.once('error', reject);
  });
  await waitForMessage(websocket, (message) => message.type === 'connected');
  return websocket;
}

async function signedWebSocketUrl(
  kind: 'daemon' | 'mobile',
  deviceId: string,
  bindingId: string,
  privateKey: KeyObject,
): Promise<string> {
  const url = new URL(`${baseUrl.replace(/^http/, 'ws')}/ws/${kind}`);
  url.searchParams.set('deviceId', deviceId);
  url.searchParams.set('bindingId', bindingId);
  const challenge = await issueSocketChallenge(deviceId, bindingId);
  url.searchParams.set('authChallengeId', challenge.id);
  url.searchParams.set('authChallengeSignature', sign(null, Buffer.from(challenge.message), privateKey).toString('base64'));
  return url.toString();
}

async function issueSocketChallenge(deviceId: string, bindingId: string): Promise<ChallengeResponse['challenge']> {
  const response = await postJson<ChallengeResponse>('/api/ws/challenge', { deviceId, bindingId });
  return response.challenge;
}

function waitForMessage(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => boolean,
): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      websocket.off('message', onMessage);
      reject(new Error('timed out waiting for websocket message'));
    }, 3000);
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

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
