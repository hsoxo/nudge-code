import { createPublicKey, randomUUID, verify } from 'node:crypto';

export interface SocketSignatureDevice {
  id: string;
  publicKey: string;
}

export interface SocketSignatureInput {
  device: SocketSignatureDevice;
  bindingId: string | undefined;
  params: URLSearchParams;
  requireSignature: boolean;
  requireChallenge?: boolean;
  nowMs?: number;
  nonceStore?: SocketNonceStore;
  challengeStore?: SocketChallengeStore;
}

export interface DeviceKeyRotationInput {
  device: SocketSignatureDevice;
  newPublicKey: string | undefined;
  signedAt: string | undefined;
  nonce: string | undefined;
  signature: string | undefined;
  nowMs?: number;
  nonceStore?: SocketNonceStore;
}

export type SignatureAuthorization =
  | { ok: true }
  | { ok: false; error: string };

export interface SocketNonceStore {
  use(key: string, expiresAtMs: number, nowMs: number): boolean;
}

export interface SocketChallenge {
  id: string;
  deviceId: string;
  bindingId: string;
  message: string;
  expiresAt: string;
  expiresAtMs: number;
}

export interface SocketChallengeStore {
  issue(input: {
    deviceId: string;
    bindingId: string;
    ttlMs: number;
    nowMs?: number;
  }): SocketChallenge;
  consume(input: {
    id: string;
    deviceId: string;
    bindingId: string;
    nowMs: number;
  }): SocketChallenge | undefined;
}

export function verifySocketSignature(input: SocketSignatureInput): SignatureAuthorization {
  const challengeId = input.params.get('authChallengeId') ?? undefined;
  const challengeSignature = input.params.get('authChallengeSignature') ?? undefined;
  const hasChallengeFields = Boolean(challengeId || challengeSignature);
  if (hasChallengeFields) {
    return verifySocketChallengeSignature({
      ...input,
      challengeId,
      signature: challengeSignature,
    });
  }
  if (input.requireChallenge) {
    return { ok: false, error: 'missing_socket_challenge' };
  }

  const timestamp = input.params.get('authTimestamp') ?? undefined;
  const nonce = input.params.get('authNonce') ?? undefined;
  const signature = input.params.get('authSignature') ?? undefined;
  const hasSignatureFields = Boolean(timestamp || nonce || signature);
  if (!hasSignatureFields && !input.requireSignature) {
    return { ok: true };
  }
  if (!input.bindingId || !timestamp || !nonce || !signature) {
    return { ok: false, error: 'missing_socket_signature' };
  }
  if (!/^\d+$/.test(timestamp)) {
    return { ok: false, error: 'invalid_socket_signature_timestamp' };
  }
  const timestampMs = Number.parseInt(timestamp, 10);
  const nowMs = input.nowMs ?? Date.now();
  if (!Number.isSafeInteger(timestampMs) || Math.abs(nowMs - timestampMs) > 5 * 60 * 1000) {
    return { ok: false, error: 'stale_socket_signature' };
  }
  if (nonce.length < 16 || nonce.length > 128) {
    return { ok: false, error: 'invalid_socket_signature_nonce' };
  }

  let signatureBytes: Buffer;
  try {
    signatureBytes = Buffer.from(signature, 'base64');
  } catch {
    return { ok: false, error: 'invalid_socket_signature' };
  }
  if (signatureBytes.length === 0) {
    return { ok: false, error: 'invalid_socket_signature' };
  }

  try {
    const key = createPublicKeyFromBase64(input.device.publicKey);
    const message = socketSignatureMessage({
      deviceId: input.device.id,
      bindingId: input.bindingId,
      timestamp,
      nonce,
    });
    if (!verify(null, Buffer.from(message), key, signatureBytes)) {
      return { ok: false, error: 'invalid_socket_signature' };
    }
    const nonceKey = `${input.device.id}\n${input.bindingId}\n${nonce}`;
    if (input.nonceStore && !input.nonceStore.use(nonceKey, timestampMs + 5 * 60 * 1000, nowMs)) {
      return { ok: false, error: 'replayed_socket_signature_nonce' };
    }
    return { ok: true };
  } catch {
    return { ok: false, error: 'invalid_socket_public_key' };
  }
}

export function verifyDeviceKeyRotation(input: DeviceKeyRotationInput): SignatureAuthorization {
  if (!input.newPublicKey || !input.signedAt || !input.nonce || !input.signature) {
    return { ok: false, error: 'missing_device_key_rotation_signature' };
  }
  if (input.newPublicKey === input.device.publicKey) {
    return { ok: false, error: 'unchanged_device_public_key' };
  }
  if (!/^\d+$/.test(input.signedAt)) {
    return { ok: false, error: 'invalid_device_key_rotation_timestamp' };
  }
  const signedAtMs = Number.parseInt(input.signedAt, 10);
  const nowMs = input.nowMs ?? Date.now();
  if (!Number.isSafeInteger(signedAtMs) || Math.abs(nowMs - signedAtMs) > 5 * 60 * 1000) {
    return { ok: false, error: 'stale_device_key_rotation_signature' };
  }
  if (input.nonce.length < 16 || input.nonce.length > 128) {
    return { ok: false, error: 'invalid_device_key_rotation_nonce' };
  }

  let signatureBytes: Buffer;
  try {
    signatureBytes = Buffer.from(input.signature, 'base64');
  } catch {
    return { ok: false, error: 'invalid_device_key_rotation_signature' };
  }
  if (signatureBytes.length === 0) {
    return { ok: false, error: 'invalid_device_key_rotation_signature' };
  }

  try {
    createPublicKeyFromBase64(input.newPublicKey);
    const currentKey = createPublicKeyFromBase64(input.device.publicKey);
    const message = deviceKeyRotationMessage({
      deviceId: input.device.id,
      currentPublicKey: input.device.publicKey,
      newPublicKey: input.newPublicKey,
      signedAt: input.signedAt,
      nonce: input.nonce,
    });
    if (!verify(null, Buffer.from(message), currentKey, signatureBytes)) {
      return { ok: false, error: 'invalid_device_key_rotation_signature' };
    }
    const nonceKey = `${input.device.id}\nkey-rotation\n${input.nonce}`;
    if (input.nonceStore && !input.nonceStore.use(nonceKey, signedAtMs + 5 * 60 * 1000, nowMs)) {
      return { ok: false, error: 'replayed_device_key_rotation_nonce' };
    }
    return { ok: true };
  } catch {
    return { ok: false, error: 'invalid_device_key_rotation_public_key' };
  }
}

function verifySocketChallengeSignature(input: SocketSignatureInput & {
  challengeId: string | undefined;
  signature: string | undefined;
}): SignatureAuthorization {
  if (!input.bindingId || !input.challengeId || !input.signature) {
    return { ok: false, error: 'missing_socket_challenge' };
  }

  let signatureBytes: Buffer;
  try {
    signatureBytes = Buffer.from(input.signature, 'base64');
  } catch {
    return { ok: false, error: 'invalid_socket_signature' };
  }
  if (signatureBytes.length === 0) {
    return { ok: false, error: 'invalid_socket_signature' };
  }

  const nowMs = input.nowMs ?? Date.now();
  const challenge = input.challengeStore?.consume({
    id: input.challengeId,
    deviceId: input.device.id,
    bindingId: input.bindingId,
    nowMs,
  });
  if (!challenge) {
    return { ok: false, error: 'invalid_socket_challenge' };
  }

  try {
    const key = createPublicKeyFromBase64(input.device.publicKey);
    if (!verify(null, Buffer.from(challenge.message), key, signatureBytes)) {
      return { ok: false, error: 'invalid_socket_signature' };
    }
    return { ok: true };
  } catch {
    return { ok: false, error: 'invalid_socket_public_key' };
  }
}

export class MemorySocketNonceStore implements SocketNonceStore {
  private readonly usedNonces = new Map<string, number>();

  use(key: string, expiresAtMs: number, nowMs: number): boolean {
    this.prune(nowMs);
    if (this.usedNonces.has(key)) {
      return false;
    }
    this.usedNonces.set(key, expiresAtMs);
    return true;
  }

  private prune(nowMs: number): void {
    for (const [key, expiresAtMs] of this.usedNonces.entries()) {
      if (expiresAtMs <= nowMs) {
        this.usedNonces.delete(key);
      }
    }
  }
}

export class MemorySocketChallengeStore implements SocketChallengeStore {
  private readonly challenges = new Map<string, SocketChallenge>();

  issue(input: {
    deviceId: string;
    bindingId: string;
    ttlMs: number;
    nowMs?: number;
  }): SocketChallenge {
    const nowMs = input.nowMs ?? Date.now();
    this.prune(nowMs);
    const id = `challenge_${randomUUID()}`;
    const expiresAtMs = nowMs + input.ttlMs;
    const expiresAt = new Date(expiresAtMs).toISOString();
    const message = socketChallengeMessage({
      deviceId: input.deviceId,
      bindingId: input.bindingId,
      challengeId: id,
      expiresAt,
    });
    const challenge: SocketChallenge = {
      id,
      deviceId: input.deviceId,
      bindingId: input.bindingId,
      message,
      expiresAt,
      expiresAtMs,
    };
    this.challenges.set(id, challenge);
    return challenge;
  }

  consume(input: {
    id: string;
    deviceId: string;
    bindingId: string;
    nowMs: number;
  }): SocketChallenge | undefined {
    this.prune(input.nowMs);
    const challenge = this.challenges.get(input.id);
    if (
      !challenge ||
      challenge.deviceId !== input.deviceId ||
      challenge.bindingId !== input.bindingId ||
      challenge.expiresAtMs <= input.nowMs
    ) {
      return undefined;
    }
    this.challenges.delete(input.id);
    return challenge;
  }

  private prune(nowMs: number): void {
    for (const [id, challenge] of this.challenges.entries()) {
      if (challenge.expiresAtMs <= nowMs) {
        this.challenges.delete(id);
      }
    }
  }
}

export function socketSignatureMessage(parts: {
  deviceId: string;
  bindingId: string;
  timestamp: string;
  nonce: string;
}): string {
  return [
    'nudge.relay.websocket.v1',
    parts.deviceId,
    parts.bindingId,
    parts.timestamp,
    parts.nonce,
  ].join('\n');
}

export function socketChallengeMessage(parts: {
  deviceId: string;
  bindingId: string;
  challengeId: string;
  expiresAt: string;
}): string {
  return [
    'nudge.relay.websocket.challenge.v1',
    parts.deviceId,
    parts.bindingId,
    parts.challengeId,
    parts.expiresAt,
  ].join('\n');
}

export function deviceKeyRotationMessage(parts: {
  deviceId: string;
  currentPublicKey: string;
  newPublicKey: string;
  signedAt: string;
  nonce: string;
}): string {
  return [
    'nudge.relay.device_key_rotation.v1',
    parts.deviceId,
    parts.currentPublicKey,
    parts.newPublicKey,
    parts.signedAt,
    parts.nonce,
  ].join('\n');
}

function createPublicKeyFromBase64(publicKey: string): ReturnType<typeof createPublicKey> {
  const bytes = Buffer.from(publicKey, 'base64');
  try {
    return createPublicKey({
      key: bytes,
      format: 'der',
      type: 'spki',
    });
  } catch {
    if (bytes.length !== 32) {
      throw new Error('unsupported Ed25519 public key format');
    }
    return createPublicKey({
      key: Buffer.concat([
        Buffer.from('302a300506032b6570032100', 'hex'),
        bytes,
      ]),
      format: 'der',
      type: 'spki',
    });
  }
}
