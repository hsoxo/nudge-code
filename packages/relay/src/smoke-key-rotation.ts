import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { WebSocket } from 'ws';
import { deviceKeyRotationMessage } from './auth.js';

interface DeviceResponse {
  device: { id: string; publicKey: string };
}

interface BindingResponse {
  binding: { id: string; code: string };
}

interface ChallengeResponse {
  challenge: { id: string; message: string };
}

const baseUrl = process.env.NUDGE_RELAY_SMOKE_URL ?? 'http://127.0.0.1:8787';

async function main(): Promise<void> {
  const daemonIdentity = generateSmokeIdentity();
  const phoneIdentity = generateSmokeIdentity();
  const rotatedPhoneIdentity = generateSmokeIdentity();
  const daemon = await registerDevice('daemon', daemonIdentity.publicKey);
  const phone = await registerDevice('phone', phoneIdentity.publicKey);
  const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
  await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phone.id });
  await postJson('/api/bind/confirm', { bindingId: binding.binding.id, daemonDeviceId: daemon.id });

  const rotated = await rotateDeviceKey({
    deviceId: phone.id,
    currentPublicKey: phoneIdentity.publicKey,
    newPublicKey: rotatedPhoneIdentity.publicKey,
    privateKey: phoneIdentity.privateKey,
  });
  if (rotated.device.publicKey !== rotatedPhoneIdentity.publicKey) {
    throw new Error(`expected rotated public key in response: ${JSON.stringify(rotated)}`);
  }

  await expectSocketRejected('mobile', phone.id, binding.binding.id, phoneIdentity.privateKey);
  const socket = await connectSocket('mobile', phone.id, binding.binding.id, rotatedPhoneIdentity.privateKey);
  socket.close();

  await expectPostError(
    '/api/devices/rotate-key',
    signedRotationBody({
      deviceId: phone.id,
      currentPublicKey: rotatedPhoneIdentity.publicKey,
      newPublicKey: rotatedPhoneIdentity.publicKey,
      privateKey: rotatedPhoneIdentity.privateKey,
    }),
    401,
    'unchanged_device_public_key',
  );

  console.log(`relay key rotation smoke passed device=${phone.id}`);
}

async function registerDevice(kind: 'daemon' | 'phone', publicKey: string): Promise<{ id: string; publicKey: string }> {
  const response = await postJson<DeviceResponse>('/api/devices/register', { kind, publicKey });
  return response.device;
}

async function rotateDeviceKey(input: {
  deviceId: string;
  currentPublicKey: string;
  newPublicKey: string;
  privateKey: KeyObject;
}): Promise<DeviceResponse> {
  return postJson<DeviceResponse>('/api/devices/rotate-key', signedRotationBody(input));
}

function signedRotationBody(input: {
  deviceId: string;
  currentPublicKey: string;
  newPublicKey: string;
  privateKey: KeyObject;
}): Record<string, string> {
  const signedAt = String(Date.now());
  const nonce = `rotation-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const message = deviceKeyRotationMessage({
    deviceId: input.deviceId,
    currentPublicKey: input.currentPublicKey,
    newPublicKey: input.newPublicKey,
    signedAt,
    nonce,
  });
  return {
    deviceId: input.deviceId,
    newPublicKey: input.newPublicKey,
    signedAt,
    nonce,
    signature: sign(null, Buffer.from(message), input.privateKey).toString('base64'),
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
  const wsUrl = await signedWebSocketUrl(kind, deviceId, bindingId, privateKey);
  const websocket = new WebSocket(wsUrl);
  await new Promise<void>((resolve, reject) => {
    websocket.once('open', () => reject(new Error('old key unexpectedly opened websocket')));
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
  const challenge = await issueSocketChallenge(deviceId, bindingId);
  url.searchParams.set('authChallengeId', challenge.id);
  url.searchParams.set('authChallengeSignature', sign(null, Buffer.from(challenge.message), privateKey).toString('base64'));
  return url.toString();
}

async function issueSocketChallenge(deviceId: string, bindingId: string): Promise<ChallengeResponse['challenge']> {
  const response = await postJson<ChallengeResponse>('/api/ws/challenge', { deviceId, bindingId });
  return response.challenge;
}

function generateSmokeIdentity(): { publicKey: string; privateKey: KeyObject } {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return {
    publicKey: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64'),
    privateKey,
  };
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
