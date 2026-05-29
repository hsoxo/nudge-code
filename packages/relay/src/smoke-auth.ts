import { generateKeyPairSync, sign } from 'node:crypto';
import {
  MemorySocketChallengeStore,
  MemorySocketNonceStore,
  socketSignatureMessage,
  verifySocketSignature,
} from './auth.js';

const nowMs = Date.parse('2026-05-29T00:00:00.000Z');
const deviceId = 'phone_1';
const bindingId = 'bind_1';
const timestamp = String(nowMs);
const nonce = 'nonce-1234567890';

const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const publicKeyBase64 = publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
const rawPublicKeyBase64 = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
const message = socketSignatureMessage({ deviceId, bindingId, timestamp, nonce });
const signature = sign(null, Buffer.from(message), privateKey).toString('base64');

const validParams = new URLSearchParams({
  authTimestamp: timestamp,
  authNonce: nonce,
  authSignature: signature,
});

expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: publicKeyBase64 },
  bindingId,
  params: validParams,
  requireSignature: true,
  nowMs,
}));

expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: rawPublicKeyBase64 },
  bindingId,
  params: validParams,
  requireSignature: true,
  nowMs,
}));

const nonceStore = new MemorySocketNonceStore();
expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: publicKeyBase64 },
  bindingId,
  params: validParams,
  requireSignature: true,
  nowMs,
  nonceStore,
}));

expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: validParams,
    requireSignature: true,
    nowMs,
    nonceStore,
  }),
  'replayed_socket_signature_nonce',
);

expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: publicKeyBase64 },
  bindingId,
  params: signedParams('nonce-after-prune-1', timestamp),
  requireSignature: true,
  nowMs,
  nonceStore,
}));

expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: validParams,
    requireSignature: true,
    requireChallenge: true,
    nowMs,
  }),
  'missing_socket_challenge',
);

const challengeStore = new MemorySocketChallengeStore();
const challenge = challengeStore.issue({ deviceId, bindingId, ttlMs: 60_000, nowMs });
const challengeParams = new URLSearchParams({
  authChallengeId: challenge.id,
  authChallengeSignature: sign(null, Buffer.from(challenge.message), privateKey).toString('base64'),
});

expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: publicKeyBase64 },
  bindingId,
  params: challengeParams,
  requireSignature: true,
  requireChallenge: true,
  nowMs,
  challengeStore,
}));

expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: challengeParams,
    requireSignature: true,
    requireChallenge: true,
    nowMs,
    challengeStore,
  }),
  'invalid_socket_challenge',
);

const expiredChallengeStore = new MemorySocketChallengeStore();
const expiredChallenge = expiredChallengeStore.issue({ deviceId, bindingId, ttlMs: 60_000, nowMs });
expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: new URLSearchParams({
      authChallengeId: expiredChallenge.id,
      authChallengeSignature: sign(null, Buffer.from(expiredChallenge.message), privateKey).toString('base64'),
    }),
    requireSignature: true,
    requireChallenge: true,
    nowMs: nowMs + 60_001,
    challengeStore: expiredChallengeStore,
  }),
  'invalid_socket_challenge',
);

expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: publicKeyBase64 },
  bindingId,
  params: signedParams('nonce-after-prune-1', String(nowMs + 5 * 60 * 1000 + 1)),
  requireSignature: true,
  nowMs: nowMs + 5 * 60 * 1000 + 1,
  nonceStore,
}));

expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: new URLSearchParams({
      authTimestamp: timestamp,
      authNonce: nonce,
      authSignature: Buffer.from('tampered').toString('base64'),
    }),
    requireSignature: true,
    nowMs,
  }),
  'invalid_socket_signature',
);

expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: new URLSearchParams(),
    requireSignature: true,
    nowMs,
  }),
  'missing_socket_signature',
);

expectError(
  verifySocketSignature({
    device: { id: deviceId, publicKey: publicKeyBase64 },
    bindingId,
    params: validParams,
    requireSignature: true,
    nowMs: nowMs + 10 * 60 * 1000,
  }),
  'stale_socket_signature',
);

expectOk(verifySocketSignature({
  device: { id: deviceId, publicKey: publicKeyBase64 },
  bindingId,
  params: new URLSearchParams(),
  requireSignature: false,
  nowMs,
}));

console.log('relay auth smoke passed');

function signedParams(authNonce: string, authTimestamp: string): URLSearchParams {
  const signedMessage = socketSignatureMessage({
    deviceId,
    bindingId,
    timestamp: authTimestamp,
    nonce: authNonce,
  });
  return new URLSearchParams({
    authTimestamp,
    authNonce,
    authSignature: sign(null, Buffer.from(signedMessage), privateKey).toString('base64'),
  });
}

function expectOk(result: ReturnType<typeof verifySocketSignature>): void {
  if (!result.ok) {
    throw new Error(`expected ok, got ${result.error}`);
  }
}

function expectError(result: ReturnType<typeof verifySocketSignature>, error: string): void {
  if (result.ok || result.error !== error) {
    throw new Error(`expected ${error}, got ${JSON.stringify(result)}`);
  }
}
