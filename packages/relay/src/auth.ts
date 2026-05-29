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
}

export type SignatureAuthorization =
  | { ok: true }
  | { ok: false; error: string };

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
    return verify(null, Buffer.from(message), key, signatureBytes)
      ? { ok: true }
      : { ok: false, error: 'invalid_socket_signature' };
  } catch {
    return { ok: false, error: 'invalid_socket_public_key' };
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
