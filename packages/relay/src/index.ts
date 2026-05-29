import { randomUUID } from 'node:crypto';
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { dirname } from 'node:path';
import { WebSocketServer, type WebSocket } from 'ws';
import { FREE_ENTITLEMENT } from '@nudge/protocol-ts';
import { MemorySocketChallengeStore, MemorySocketNonceStore, verifySocketSignature } from './auth.js';

type DeviceKind = 'daemon' | 'phone';
type BindingStatus = 'pending' | 'claimed' | 'active' | 'revoked';

interface Device {
  id: string;
  kind: DeviceKind;
  publicKey: string;
  createdAt: string;
}

interface Binding {
  id: string;
  code: string;
  daemonDeviceId: string;
  phoneDeviceId?: string;
  status: BindingStatus;
  createdAt: string;
  expiresAt: string;
  claimedAt?: string;
  confirmedAt?: string;
  revokedAt?: string;
}

interface RelayMessage {
  id: string;
  bindingId: string;
  fromDeviceId: string;
  toDeviceId: string;
  ephemeral: boolean;
  payload: unknown;
  createdAt: string;
}

interface PersistedRelayState {
  version: 1;
  devices: Device[];
  bindings: Binding[];
  updatedAt: string;
}

type AuditEventType =
  | 'device_registered'
  | 'binding_started'
  | 'binding_claimed'
  | 'binding_confirmed'
  | 'binding_revoked'
  | 'pairing_claim_rejected'
  | 'socket_challenge_issued'
  | 'socket_authorized'
  | 'socket_rejected'
  | 'message_routed'
  | 'message_queued'
  | 'message_poll'
  | 'message_rejected';

type RateLimitResult =
  | { ok: true }
  | { ok: false; retryAfterSeconds: number };

class FixedWindowRateLimiter {
  private readonly attempts = new Map<string, { count: number; resetAt: number }>();
  private pruneAt = 0;

  constructor(
    private readonly maxAttempts: number,
    private readonly windowMs: number,
  ) {}

  hit(key: string, nowMs = Date.now()): RateLimitResult {
    if (this.maxAttempts <= 0 || this.windowMs <= 0) {
      return { ok: true };
    }
    this.prune(nowMs);
    const existing = this.attempts.get(key);
    if (!existing || existing.resetAt <= nowMs) {
      this.attempts.set(key, { count: 1, resetAt: nowMs + this.windowMs });
      return { ok: true };
    }
    if (existing.count >= this.maxAttempts) {
      return {
        ok: false,
        retryAfterSeconds: Math.max(1, Math.ceil((existing.resetAt - nowMs) / 1000)),
      };
    }
    existing.count += 1;
    return { ok: true };
  }

  private prune(nowMs: number): void {
    if (nowMs < this.pruneAt) {
      return;
    }
    this.pruneAt = nowMs + Math.min(this.windowMs, 60_000);
    for (const [key, attempt] of this.attempts) {
      if (attempt.resetAt <= nowMs) {
        this.attempts.delete(key);
      }
    }
  }
}

const port = Number.parseInt(process.env.NUDGE_RELAY_PORT ?? '8787', 10);
const requireWebSocketSignature = process.env.NUDGE_RELAY_REQUIRE_WS_SIGNATURE === '1';
const requireWebSocketChallenge = process.env.NUDGE_RELAY_REQUIRE_WS_CHALLENGE === '1';
const requireE2EPayload = process.env.NUDGE_RELAY_REQUIRE_E2E_PAYLOAD === '1';
const relayStatePath = process.env.NUDGE_RELAY_STATE_PATH;
const relayAuditPath = process.env.NUDGE_RELAY_AUDIT_PATH;
const trustProxyHeaders = process.env.NUDGE_RELAY_TRUST_PROXY === '1';
const socketChallengeTtlMs = readPositiveIntEnv('NUDGE_SOCKET_CHALLENGE_TTL_MS', 60_000);
const pairingClaimWindowMs = readPositiveIntEnv('NUDGE_PAIRING_CLAIM_RATE_WINDOW_MS', 10 * 60 * 1000);
const pairingClaimIpLimit = readPositiveIntEnv('NUDGE_PAIRING_CLAIM_IP_LIMIT', 60);
const pairingClaimCodeLimit = readPositiveIntEnv('NUDGE_PAIRING_CLAIM_CODE_LIMIT', 10);
const devices = new Map<string, Device>();
const bindings = new Map<string, Binding>();
const messages = new Map<string, RelayMessage[]>();
const sockets = new Map<string, WebSocket>();
const nonceStore = new MemorySocketNonceStore();
const challengeStore = new MemorySocketChallengeStore();
const pairingClaimIpLimiter = new FixedWindowRateLimiter(pairingClaimIpLimit, pairingClaimWindowMs);
const pairingClaimCodeLimiter = new FixedWindowRateLimiter(pairingClaimCodeLimit, pairingClaimWindowMs);

loadRelayState();

const server = createServer(async (request, response) => {
  try {
    await route(request, response);
  } catch (error) {
    writeJson(response, 500, {
      error: 'internal_error',
      message: error instanceof Error ? error.message : String(error),
    });
  }
});
const websocketServer = new WebSocketServer({ noServer: true });

server.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  if (url.pathname !== '/ws/daemon' && url.pathname !== '/ws/mobile') {
    socket.destroy();
    return;
  }
  const expectedKind: DeviceKind = url.pathname === '/ws/daemon' ? 'daemon' : 'phone';
  const authorization = authorizeSocket(expectedKind, url.searchParams);
  if (!authorization.ok) {
    audit('socket_rejected', {
      deviceKind: expectedKind,
      deviceId: url.searchParams.get('deviceId') ?? undefined,
      bindingId: url.searchParams.get('bindingId') ?? undefined,
      error: authorization.error,
    });
    socket.write(`HTTP/1.1 ${authorization.statusCode} ${authorization.error}\r\n\r\n`);
    socket.destroy();
    return;
  }

  websocketServer.handleUpgrade(request, socket, head, (websocket) => {
    audit('socket_authorized', {
      deviceKind: authorization.device.kind,
      deviceId: authorization.device.id,
      bindingId: authorization.binding.id,
    });
    bindWebSocket(websocket, authorization.device, authorization.binding);
  });
});

async function route(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const method = request.method ?? 'GET';
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);

  if (method === 'GET' && url.pathname === '/healthz') {
    writeJson(response, 200, { ok: true, service: 'nudge-relay' });
    return;
  }

  if (method === 'GET' && url.pathname === '/entitlement/free') {
    writeJson(response, 200, FREE_ENTITLEMENT);
    return;
  }

  if (method === 'POST' && url.pathname === '/api/devices/register') {
    const body = await readJson<{ kind?: string; publicKey?: string }>(request);
    if (body.kind !== 'daemon' && body.kind !== 'phone') {
      writeJson(response, 400, { error: 'invalid_device_kind' });
      return;
    }
    if (!body.publicKey) {
      writeJson(response, 400, { error: 'missing_public_key' });
      return;
    }
    const device: Device = {
      id: `${body.kind}_${randomUUID()}`,
      kind: body.kind,
      publicKey: body.publicKey,
      createdAt: now(),
    };
    devices.set(device.id, device);
    persistRelayState();
    audit('device_registered', { deviceKind: device.kind, deviceId: device.id });
    writeJson(response, 201, { device });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/ws/challenge') {
    const body = await readJson<{ deviceId?: string; bindingId?: string }>(request);
    const device = body.deviceId ? devices.get(body.deviceId) : undefined;
    const binding = body.bindingId ? bindings.get(body.bindingId) : undefined;
    if (!device) {
      writeJson(response, 401, { error: 'device_not_registered' });
      return;
    }
    if (!binding || binding.status !== 'active') {
      writeJson(response, 403, { error: 'binding_not_active' });
      return;
    }
    if (!isBindingParticipant(binding, device.id)) {
      writeJson(response, 403, { error: 'route_not_authorized' });
      return;
    }
    const challenge = challengeStore.issue({
      deviceId: device.id,
      bindingId: binding.id,
      ttlMs: socketChallengeTtlMs,
    });
    audit('socket_challenge_issued', {
      deviceKind: device.kind,
      deviceId: device.id,
      bindingId: binding.id,
      challengeId: challenge.id,
    });
    writeJson(response, 201, {
      challenge: {
        id: challenge.id,
        message: challenge.message,
        expiresAt: challenge.expiresAt,
      },
    });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/bind/start') {
    const body = await readJson<{ daemonDeviceId?: string }>(request);
    const daemon = body.daemonDeviceId ? devices.get(body.daemonDeviceId) : undefined;
    if (!daemon || daemon.kind !== 'daemon') {
      writeJson(response, 404, { error: 'daemon_not_registered' });
      return;
    }
    if (activeBindingForDaemon(daemon.id)) {
      writeJson(response, 409, { error: 'daemon_already_bound' });
      return;
    }
    const binding: Binding = {
      id: `bind_${randomUUID()}`,
      code: makePairingCode(),
      daemonDeviceId: daemon.id,
      status: 'pending',
      createdAt: now(),
      expiresAt: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    };
    bindings.set(binding.id, binding);
    persistRelayState();
    audit('binding_started', {
      bindingId: binding.id,
      daemonDeviceId: daemon.id,
      expiresAt: binding.expiresAt,
    });
    writeJson(response, 201, { binding });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/bind/claim') {
    const body = await readJson<{ code?: string; phoneDeviceId?: string }>(request);
    const pairingCode = normalizePairingCode(body.code);
    const rateLimit = checkPairingClaimRateLimit(request, pairingCode);
    if (!rateLimit.ok) {
      response.setHeader('retry-after', String(rateLimit.retryAfterSeconds));
      audit('pairing_claim_rejected', {
        deviceId: body.phoneDeviceId,
        error: 'pairing_rate_limited',
        retryAfterSeconds: rateLimit.retryAfterSeconds,
      });
      writeJson(response, 429, {
        error: 'pairing_rate_limited',
        retryAfterSeconds: rateLimit.retryAfterSeconds,
      });
      return;
    }
    const phone = body.phoneDeviceId ? devices.get(body.phoneDeviceId) : undefined;
    if (!phone || phone.kind !== 'phone') {
      audit('pairing_claim_rejected', {
        deviceId: body.phoneDeviceId,
        error: 'phone_not_registered',
      });
      writeJson(response, 404, { error: 'phone_not_registered' });
      return;
    }
    if (activeBindingsForPhone(phone.id).length >= FREE_ENTITLEMENT.maxBoundComputers) {
      audit('pairing_claim_rejected', {
        deviceId: phone.id,
        error: 'free_entitlement_computer_limit',
      });
      writeJson(response, 409, { error: 'free_entitlement_computer_limit' });
      return;
    }
    const binding = findBindingByCode(pairingCode);
    if (!binding || binding.status !== 'pending') {
      audit('pairing_claim_rejected', {
        deviceId: phone.id,
        error: 'pairing_code_not_found',
      });
      writeJson(response, 404, { error: 'pairing_code_not_found' });
      return;
    }
    if (Date.parse(binding.expiresAt) < Date.now()) {
      audit('pairing_claim_rejected', {
        bindingId: binding.id,
        deviceId: phone.id,
        error: 'pairing_code_expired',
      });
      writeJson(response, 410, { error: 'pairing_code_expired' });
      return;
    }
    binding.phoneDeviceId = phone.id;
    binding.status = 'claimed';
    binding.claimedAt = now();
    persistRelayState();
    audit('binding_claimed', {
      bindingId: binding.id,
      daemonDeviceId: binding.daemonDeviceId,
      phoneDeviceId: phone.id,
    });
    writeJson(response, 200, { binding });
    return;
  }

  if (method === 'GET' && url.pathname === '/api/bind/status') {
    const bindingId = url.searchParams.get('bindingId') ?? undefined;
    const deviceId = url.searchParams.get('deviceId') ?? undefined;
    const binding = bindingId ? bindings.get(bindingId) : undefined;
    if (!binding || !isBindingParticipant(binding, deviceId)) {
      writeJson(response, 404, { error: 'binding_not_found' });
      return;
    }
    writeJson(response, 200, { binding });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/bind/confirm') {
    const body = await readJson<{ bindingId?: string; daemonDeviceId?: string }>(request);
    const binding = body.bindingId ? bindings.get(body.bindingId) : undefined;
    if (!binding || binding.status !== 'claimed') {
      writeJson(response, 404, { error: 'claimed_binding_not_found' });
      return;
    }
    if (binding.daemonDeviceId !== body.daemonDeviceId) {
      writeJson(response, 403, { error: 'daemon_not_authorized_for_binding' });
      return;
    }
    if (!binding.phoneDeviceId) {
      writeJson(response, 409, { error: 'binding_has_no_phone' });
      return;
    }
    binding.status = 'active';
    binding.confirmedAt = now();
    persistRelayState();
    audit('binding_confirmed', {
      bindingId: binding.id,
      daemonDeviceId: binding.daemonDeviceId,
      phoneDeviceId: binding.phoneDeviceId,
    });
    writeJson(response, 200, { binding, entitlement: FREE_ENTITLEMENT });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/bind/revoke') {
    const body = await readJson<{ bindingId?: string; deviceId?: string }>(request);
    const binding = body.bindingId ? bindings.get(body.bindingId) : undefined;
    if (!binding || !isBindingParticipant(binding, body.deviceId)) {
      writeJson(response, 404, { error: 'binding_not_found' });
      return;
    }
    binding.status = 'revoked';
    binding.revokedAt = now();
    closeBindingSockets(binding, 'binding_revoked');
    clearBindingQueues(binding);
    persistRelayState();
    audit('binding_revoked', {
      bindingId: binding.id,
      daemonDeviceId: binding.daemonDeviceId,
      phoneDeviceId: binding.phoneDeviceId,
      actorDeviceId: body.deviceId,
    });
    writeJson(response, 200, { binding });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/messages/send') {
    const body = await readJson<{
      bindingId?: string;
      fromDeviceId?: string;
      toDeviceId?: string;
      ephemeral?: boolean;
      payload?: unknown;
    }>(request);
    const binding = body.bindingId ? bindings.get(body.bindingId) : undefined;
    if (!binding || binding.status !== 'active') {
      writeJson(response, 403, { error: 'binding_not_active' });
      return;
    }
    if (!isBindingParticipant(binding, body.fromDeviceId) || !isBindingParticipant(binding, body.toDeviceId)) {
      writeJson(response, 403, { error: 'route_not_authorized' });
      return;
    }
    if (body.fromDeviceId === body.toDeviceId) {
      writeJson(response, 400, { error: 'same_source_and_destination' });
      return;
    }
    const payloadValidation = validateRelayPayload(body.payload);
    if (!payloadValidation.ok) {
      audit('message_rejected', {
        bindingId: binding.id,
        fromDeviceId: body.fromDeviceId,
        toDeviceId: body.toDeviceId,
        error: payloadValidation.error,
        payloadType: payloadType(body.payload),
      });
      writeJson(response, 400, { error: payloadValidation.error });
      return;
    }
    const message: RelayMessage = {
      id: `msg_${randomUUID()}`,
      bindingId: binding.id,
      fromDeviceId: body.fromDeviceId,
      toDeviceId: body.toDeviceId,
      ephemeral: body.ephemeral === true,
      payload: body.payload ?? {},
      createdAt: now(),
    };
    const targetSocket = sockets.get(message.toDeviceId);
    if (targetSocket && targetSocket.readyState === targetSocket.OPEN) {
      targetSocket.send(JSON.stringify({ type: 'message', message }));
      audit('message_routed', {
        bindingId: binding.id,
        fromDeviceId: message.fromDeviceId,
        toDeviceId: message.toDeviceId,
        ephemeral: message.ephemeral,
        payloadType: payloadType(message.payload),
      });
    } else if (!message.ephemeral) {
      const queue = messages.get(message.toDeviceId) ?? [];
      queue.push(message);
      messages.set(message.toDeviceId, queue);
      audit('message_queued', {
        bindingId: binding.id,
        fromDeviceId: message.fromDeviceId,
        toDeviceId: message.toDeviceId,
        ephemeral: message.ephemeral,
        payloadType: payloadType(message.payload),
      });
    }
    writeJson(response, 202, { accepted: true, messageId: message.id });
    return;
  }

  if (method === 'GET' && url.pathname === '/api/messages/poll') {
    const deviceId = url.searchParams.get('deviceId') ?? undefined;
    if (!deviceId || !devices.has(deviceId)) {
      writeJson(response, 404, { error: 'device_not_registered' });
      return;
    }
    const queue = messages.get(deviceId) ?? [];
    messages.set(deviceId, []);
    audit('message_poll', { deviceId, count: queue.length });
    writeJson(response, 200, { messages: queue });
    return;
  }

  writeJson(response, 404, { error: 'not_found' });
}

function activeBindingForDaemon(daemonDeviceId: string): Binding | undefined {
  return [...bindings.values()].find(
    (binding) => binding.daemonDeviceId === daemonDeviceId && binding.status === 'active',
  );
}

function activeBindingsForPhone(phoneDeviceId: string): Binding[] {
  return [...bindings.values()].filter(
    (binding) => binding.phoneDeviceId === phoneDeviceId && binding.status === 'active',
  );
}

function findBindingByCode(code: string | undefined): Binding | undefined {
  const normalizedCode = normalizePairingCode(code);
  if (!normalizedCode) {
    return undefined;
  }
  return [...bindings.values()].find((binding) => binding.code === normalizedCode);
}

function checkPairingClaimRateLimit(request: IncomingMessage, pairingCode: string | undefined): RateLimitResult {
  const addressResult = pairingClaimIpLimiter.hit(`ip:${clientAddress(request)}`);
  if (!addressResult.ok) {
    return addressResult;
  }
  if (!pairingCode) {
    return { ok: true };
  }
  return pairingClaimCodeLimiter.hit(`code:${pairingCode}`);
}

function normalizePairingCode(code: string | undefined): string | undefined {
  const normalized = code?.replace(/\s+/g, '').toUpperCase();
  return normalized ? normalized : undefined;
}

function clientAddress(request: IncomingMessage): string {
  if (trustProxyHeaders) {
    const forwardedFor = request.headers['x-forwarded-for'];
    const firstForwarded = Array.isArray(forwardedFor) ? forwardedFor[0] : forwardedFor;
    const address = firstForwarded?.split(',')[0]?.trim();
    if (address) {
      return address;
    }
  }
  return request.socket.remoteAddress ?? 'unknown';
}

function isBindingParticipant(binding: Binding, deviceId: string | undefined): deviceId is string {
  return Boolean(deviceId && (deviceId === binding.daemonDeviceId || deviceId === binding.phoneDeviceId));
}

type SocketAuthorization =
  | { ok: true; device: Device; binding: Binding }
  | { ok: false; statusCode: number; error: string };

function authorizeSocket(
  expectedKind: DeviceKind,
  params: URLSearchParams,
): SocketAuthorization {
  const deviceId = params.get('deviceId') ?? undefined;
  const bindingId = params.get('bindingId') ?? undefined;
  const device = deviceId ? devices.get(deviceId) : undefined;
  if (!device || device.kind !== expectedKind) {
    return { ok: false, statusCode: 401, error: 'device_not_registered' };
  }
  const signature = authorizeSocketSignature(device, bindingId, params);
  if (!signature.ok) {
    return { ok: false, statusCode: 401, error: signature.error };
  }
  const binding = bindingId ? bindings.get(bindingId) : undefined;
  if (!binding || binding.status !== 'active') {
    return { ok: false, statusCode: 403, error: 'binding_not_active' };
  }
  if (!isBindingParticipant(binding, device.id)) {
    return { ok: false, statusCode: 403, error: 'route_not_authorized' };
  }
  return { ok: true, device, binding };
}

type SignatureAuthorization =
  | { ok: true }
  | { ok: false; error: string };

function authorizeSocketSignature(
  device: Device,
  bindingId: string | undefined,
  params: URLSearchParams,
): SignatureAuthorization {
  return verifySocketSignature({
    device,
    bindingId,
    params,
    requireSignature: requireWebSocketSignature,
    requireChallenge: requireWebSocketChallenge,
    nonceStore,
    challengeStore,
  });
}

function bindWebSocket(websocket: WebSocket, device: Device, binding: Binding): void {
  sockets.set(device.id, websocket);
  websocket.send(JSON.stringify({ type: 'connected', deviceId: device.id, bindingId: binding.id }));
  websocket.on('message', (bytes) => {
    let message: { toDeviceId?: string; ephemeral?: boolean; payload?: unknown };
    try {
      message = JSON.parse(bytes.toString()) as { toDeviceId?: string; ephemeral?: boolean; payload?: unknown };
    } catch {
      websocket.send(JSON.stringify({ type: 'error', error: 'invalid_json' }));
      return;
    }
    if (binding.status !== 'active') {
      websocket.send(JSON.stringify({ type: 'error', error: 'binding_not_active' }));
      websocket.close(4001, 'binding_not_active');
      return;
    }
    if (!isBindingParticipant(binding, message.toDeviceId) || message.toDeviceId === device.id) {
      websocket.send(JSON.stringify({ type: 'error', error: 'route_not_authorized' }));
      return;
    }
    const payloadValidation = validateRelayPayload(message.payload);
    if (!payloadValidation.ok) {
      audit('message_rejected', {
        bindingId: binding.id,
        fromDeviceId: device.id,
        toDeviceId: message.toDeviceId,
        error: payloadValidation.error,
        payloadType: payloadType(message.payload),
      });
      websocket.send(JSON.stringify({ type: 'error', error: payloadValidation.error }));
      return;
    }
    const relayMessage: RelayMessage = {
      id: `msg_${randomUUID()}`,
      bindingId: binding.id,
      fromDeviceId: device.id,
      toDeviceId: message.toDeviceId,
      ephemeral: message.ephemeral === true,
      payload: message.payload ?? {},
      createdAt: now(),
    };
    const targetSocket = sockets.get(relayMessage.toDeviceId);
    if (targetSocket && targetSocket.readyState === targetSocket.OPEN) {
      targetSocket.send(JSON.stringify({ type: 'message', message: relayMessage }));
      audit('message_routed', {
        bindingId: binding.id,
        fromDeviceId: device.id,
        toDeviceId: relayMessage.toDeviceId,
        ephemeral: relayMessage.ephemeral,
        payloadType: payloadType(relayMessage.payload),
      });
    } else if (!relayMessage.ephemeral) {
      const queue = messages.get(relayMessage.toDeviceId) ?? [];
      queue.push(relayMessage);
      messages.set(relayMessage.toDeviceId, queue);
      audit('message_queued', {
        bindingId: binding.id,
        fromDeviceId: device.id,
        toDeviceId: relayMessage.toDeviceId,
        ephemeral: relayMessage.ephemeral,
        payloadType: payloadType(relayMessage.payload),
      });
    }
    websocket.send(JSON.stringify({ type: 'accepted', messageId: relayMessage.id }));
  });
  websocket.on('close', () => {
    if (sockets.get(device.id) === websocket) {
      sockets.delete(device.id);
    }
  });
}

function closeBindingSockets(binding: Binding, reason: string): void {
  for (const deviceId of bindingDeviceIds(binding)) {
    const socket = sockets.get(deviceId);
    if (socket && socket.readyState === socket.OPEN) {
      socket.send(JSON.stringify({ type: 'error', error: reason }));
      socket.close(4001, reason);
    }
  }
}

function clearBindingQueues(binding: Binding): void {
  const participants = new Set(bindingDeviceIds(binding));
  for (const deviceId of participants) {
    const queue = messages.get(deviceId);
    if (!queue) {
      continue;
    }
    messages.set(deviceId, queue.filter((message) => message.bindingId !== binding.id));
  }
}

function bindingDeviceIds(binding: Binding): string[] {
  return [binding.daemonDeviceId, binding.phoneDeviceId].filter((deviceId): deviceId is string => Boolean(deviceId));
}

function makePairingCode(): string {
  return randomUUID().replaceAll('-', '').slice(0, 12).toUpperCase();
}

function payloadType(payload: unknown): string | undefined {
  if (!payload || typeof payload !== 'object') {
    return undefined;
  }
  const type = (payload as { type?: unknown }).type;
  return typeof type === 'string' ? type : undefined;
}

type PayloadValidation =
  | { ok: true }
  | { ok: false; error: 'e2e_payload_required' | 'invalid_e2e_payload' };

function validateRelayPayload(payload: unknown): PayloadValidation {
  if (!requireE2EPayload) {
    return { ok: true };
  }
  if (!payload || typeof payload !== 'object') {
    return { ok: false, error: 'e2e_payload_required' };
  }
  const candidate = payload as Record<string, unknown>;
  if (candidate.type !== 'e2e_envelope') {
    return { ok: false, error: 'e2e_payload_required' };
  }
  if (
    typeof candidate.version !== 'number' ||
    !Number.isInteger(candidate.version) ||
    candidate.version < 1 ||
    typeof candidate.messageType !== 'string' ||
    typeof candidate.ciphertextBase64 !== 'string' ||
    typeof candidate.nonceBase64 !== 'string' ||
    typeof candidate.senderKeyId !== 'string' ||
    typeof candidate.recipientKeyId !== 'string'
  ) {
    return { ok: false, error: 'invalid_e2e_payload' };
  }
  if (!isBase64(candidate.ciphertextBase64) || !isBase64(candidate.nonceBase64)) {
    return { ok: false, error: 'invalid_e2e_payload' };
  }
  return { ok: true };
}

function isBase64(value: string): boolean {
  if (value.length === 0 || value.length % 4 !== 0) {
    return false;
  }
  return /^[A-Za-z0-9+/]+={0,2}$/.test(value);
}

function audit(type: AuditEventType, fields: Record<string, unknown> = {}): void {
  if (!relayAuditPath) {
    return;
  }
  const event = {
    ts: now(),
    type,
    ...redactAuditFields(fields),
  };
  mkdirSync(dirname(relayAuditPath), { recursive: true });
  appendFileSync(relayAuditPath, `${JSON.stringify(event)}\n`, { mode: 0o600 });
  chmodSync(relayAuditPath, 0o600);
}

function redactAuditFields(fields: Record<string, unknown>): Record<string, unknown> {
  const redacted: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) {
      continue;
    }
    if (key === 'code' || key === 'publicKey' || key === 'payload' || key === 'message') {
      redacted[key] = '[redacted]';
      continue;
    }
    redacted[key] = value;
  }
  return redacted;
}

function now(): string {
  return new Date().toISOString();
}

function readPositiveIntEnv(name: string, fallback: number): number {
  const value = process.env[name];
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function readJson<T>(request: IncomingMessage): Promise<T> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  if (chunks.length === 0) {
    return {} as T;
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as T;
}

function writeJson(response: ServerResponse, statusCode: number, payload: unknown): void {
  response.writeHead(statusCode, { 'content-type': 'application/json' });
  response.end(JSON.stringify(payload));
}

function loadRelayState(): void {
  if (!relayStatePath || !existsSync(relayStatePath)) {
    return;
  }
  const parsed = JSON.parse(readFileSync(relayStatePath, 'utf8')) as Partial<PersistedRelayState>;
  if (parsed.version !== 1 || !Array.isArray(parsed.devices) || !Array.isArray(parsed.bindings)) {
    throw new Error(`unsupported relay state file format: ${relayStatePath}`);
  }
  for (const device of parsed.devices) {
    if (!isPersistedDevice(device)) {
      throw new Error(`invalid relay device in ${relayStatePath}`);
    }
    devices.set(device.id, device);
  }
  for (const binding of parsed.bindings) {
    if (!isPersistedBinding(binding)) {
      throw new Error(`invalid relay binding in ${relayStatePath}`);
    }
    bindings.set(binding.id, binding);
  }
  chmodSync(relayStatePath, 0o600);
}

function persistRelayState(): void {
  if (!relayStatePath) {
    return;
  }
  const state: PersistedRelayState = {
    version: 1,
    devices: [...devices.values()],
    bindings: [...bindings.values()],
    updatedAt: now(),
  };
  mkdirSync(dirname(relayStatePath), { recursive: true });
  const tmpPath = `${relayStatePath}.${process.pid}.tmp`;
  writeFileSync(tmpPath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  chmodSync(tmpPath, 0o600);
  renameSync(tmpPath, relayStatePath);
  chmodSync(relayStatePath, 0o600);
}

function isPersistedDevice(value: unknown): value is Device {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const device = value as Partial<Device>;
  return (
    typeof device.id === 'string' &&
    (device.kind === 'daemon' || device.kind === 'phone') &&
    typeof device.publicKey === 'string' &&
    typeof device.createdAt === 'string'
  );
}

function isPersistedBinding(value: unknown): value is Binding {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const binding = value as Partial<Binding>;
  return (
    typeof binding.id === 'string' &&
    typeof binding.code === 'string' &&
    typeof binding.daemonDeviceId === 'string' &&
    (binding.phoneDeviceId === undefined || typeof binding.phoneDeviceId === 'string') &&
    (binding.status === 'pending' ||
      binding.status === 'claimed' ||
      binding.status === 'active' ||
      binding.status === 'revoked') &&
    typeof binding.createdAt === 'string' &&
    typeof binding.expiresAt === 'string' &&
    (binding.claimedAt === undefined || typeof binding.claimedAt === 'string') &&
    (binding.confirmedAt === undefined || typeof binding.confirmedAt === 'string') &&
    (binding.revokedAt === undefined || typeof binding.revokedAt === 'string')
  );
}

server.listen(port, () => {
  console.log(`nudge relay listening on :${port}`);
});
