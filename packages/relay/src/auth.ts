import { createPublicKey, verify } from 'node:crypto';

export interface SocketSignatureDevice {
  id: string;
  publicKey: string;
}

export interface SocketSignatureInput {
  device: SocketSignatureDevice;
  bindingId: string | undefined;
  params: URLSearchParams;
  requireSignature: boolean;
  nowMs?: number;
  nonceStore?: SocketNonceStore;
}

export type SignatureAuthorization =
  | { ok: true }
  | { ok: false; error: string };

export interface SocketNonceStore {
  use(key: string, expiresAtMs: number, nowMs: number): boolean;
}

export function verifySocketSignature(input: SocketSignatureInput): SignatureAuthorization {
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
