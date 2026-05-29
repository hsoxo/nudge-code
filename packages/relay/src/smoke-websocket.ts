import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { WebSocket } from 'ws';
import { socketSignatureMessage } from './auth.js';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: { id: string; code: string; status?: string };
}

interface ChallengeResponse {
  challenge: { id: string; message: string };
}

const baseUrl = process.env.NUDGE_RELAY_SMOKE_URL ?? 'http://127.0.0.1:8787';
const useChallenge = process.env.NUDGE_RELAY_SMOKE_USE_CHALLENGE === '1';

async function main(): Promise<void> {
  const daemonIdentity = generateSmokeIdentity();
  const phoneIdentity = generateSmokeIdentity();
  const daemon = await registerDevice('daemon', daemonIdentity.publicKey);
  const phone = await registerDevice('phone', phoneIdentity.publicKey);
  const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
  await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phone.id });
  await postJson('/api/bind/confirm', { bindingId: binding.binding.id, daemonDeviceId: daemon.id });

  const daemonSocket = await connectSocket('daemon', daemon.id, binding.binding.id, daemonIdentity.privateKey);
  const phoneSocket = await connectSocket('mobile', phone.id, binding.binding.id, phoneIdentity.privateKey);

  const routed = waitForMessage(daemonSocket, (message) => message.type === 'message');
  phoneSocket.send(JSON.stringify({ toDeviceId: daemon.id, payload: { type: 'get_state' } }));
  const message = await routed;
  if (message.message?.payload?.type !== 'get_state') {
    throw new Error(`unexpected routed payload: ${JSON.stringify(message)}`);
  }

  const liveUpdate = waitForMessage(phoneSocket, (candidate) => candidate.type === 'message');
  daemonSocket.send(JSON.stringify({
    toDeviceId: phone.id,
    ephemeral: true,
    payload: {
      type: 'daemon_response',
      ok: true,
      data: { tabId: 'default', bytesBase64: 'bGl2ZSB1cGRhdGU=' },
    },
  }));
  const update = await liveUpdate;
  if (update.message?.payload?.data?.bytesBase64 !== 'bGl2ZSB1cGRhdGU=') {
    throw new Error(`unexpected live update payload: ${JSON.stringify(update)}`);
  }

  const daemonClosed = waitForClose(daemonSocket);
  const phoneClosed = waitForClose(phoneSocket);
  await postJson('/api/bind/revoke', { bindingId: binding.binding.id, deviceId: daemon.id });
  const daemonClose = await daemonClosed;
  const phoneClose = await phoneClosed;
  if (daemonClose.code !== 4001 || phoneClose.code !== 4001) {
    throw new Error(`expected revocation close code 4001, got ${daemonClose.code}/${phoneClose.code}`);
  }

  await expectSocketRejected('mobile', phone.id, binding.binding.id, phoneIdentity.privateKey);

  const secondDaemonIdentity = generateSmokeIdentity();
  const secondDaemon = await registerDevice('daemon', secondDaemonIdentity.publicKey);
  const secondBinding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: secondDaemon.id });
  await postJson('/api/bind/claim', { code: secondBinding.binding.code, phoneDeviceId: phone.id });
  await postJson('/api/bind/confirm', { bindingId: secondBinding.binding.id, daemonDeviceId: secondDaemon.id });

  const secondDaemonSocket = await connectSocket(
    'daemon',
    secondDaemon.id,
    secondBinding.binding.id,
    secondDaemonIdentity.privateKey,
  );
  const secondPhoneSocket = await connectSocket('mobile', phone.id, secondBinding.binding.id, phoneIdentity.privateKey);
  const secondDaemonClosed = waitForClose(secondDaemonSocket);
  const secondPhoneClosed = waitForClose(secondPhoneSocket);
  const deviceRevoke = await postJson<{ revokedBindings: Array<{ id: string; status: string }> }>('/api/devices/revoke', {
    deviceId: phone.id,
    actorDeviceId: phone.id,
  });
  if (!deviceRevoke.revokedBindings.some((candidate) => candidate.id === secondBinding.binding.id && candidate.status === 'revoked')) {
    throw new Error(`expected device revoke to revoke binding: ${JSON.stringify(deviceRevoke)}`);
  }
  const secondDaemonClose = await secondDaemonClosed;
  const secondPhoneClose = await secondPhoneClosed;
  if (secondDaemonClose.code !== 4001 || secondPhoneClose.code !== 4001) {
    throw new Error(
      `expected device revocation close code 4001, got ${secondDaemonClose.code}/${secondPhoneClose.code}`,
    );
  }
  await expectSocketRejected('mobile', phone.id, secondBinding.binding.id, phoneIdentity.privateKey);
  await expectPostError(
    '/api/bind/claim',
    { code: secondBinding.binding.code, phoneDeviceId: phone.id },
    403,
    'device_revoked',
  );

  daemonSocket.close();
  phoneSocket.close();
  secondDaemonSocket.close();
  secondPhoneSocket.close();
  console.log(`relay websocket smoke passed binding=${binding.binding.id}`);
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

async function expectSocketRejected(
  kind: 'daemon' | 'mobile',
  deviceId: string,
  bindingId: string,
  privateKey: KeyObject,
): Promise<void> {
  let wsUrl: string;
  try {
    wsUrl = await signedWebSocketUrl(kind, deviceId, bindingId, privateKey);
  } catch {
    return;
  }
  const websocket = new WebSocket(wsUrl);
  await new Promise<void>((resolve, reject) => {
    websocket.once('open', () => reject(new Error('revoked binding unexpectedly opened websocket')));
    websocket.once('error', () => resolve());
    websocket.once('close', () => resolve());
  });
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
  if (useChallenge) {
    const challenge = await issueSocketChallenge(deviceId, bindingId);
    url.searchParams.set('authChallengeId', challenge.id);
    url.searchParams.set('authChallengeSignature', sign(null, Buffer.from(challenge.message), privateKey).toString('base64'));
  } else {
    const timestamp = String(Date.now());
    const nonce = `nonce-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const message = socketSignatureMessage({ deviceId, bindingId, timestamp, nonce });
    url.searchParams.set('authTimestamp', timestamp);
    url.searchParams.set('authNonce', nonce);
    url.searchParams.set('authSignature', sign(null, Buffer.from(message), privateKey).toString('base64'));
  }
  return url.toString();
}

async function issueSocketChallenge(deviceId: string, bindingId: string): Promise<ChallengeResponse['challenge']> {
  const response = await postJson<ChallengeResponse>('/api/ws/challenge', { deviceId, bindingId });
  return response.challenge;
}

function waitForClose(websocket: WebSocket): Promise<{ code: number; reason: string }> {
  return new Promise((resolve) => {
    websocket.once('close', (code, reason) => {
      resolve({ code, reason: reason.toString('utf8') });
    });
  });
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

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
