import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import { FREE_ENTITLEMENT } from '@nudge/protocol-ts';

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
  payload: unknown;
  createdAt: string;
}

const port = Number.parseInt(process.env.NUDGE_RELAY_PORT ?? '8787', 10);
const devices = new Map<string, Device>();
const bindings = new Map<string, Binding>();
const messages = new Map<string, RelayMessage[]>();

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
    writeJson(response, 201, { device });
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
    writeJson(response, 201, { binding });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/bind/claim') {
    const body = await readJson<{ code?: string; phoneDeviceId?: string }>(request);
    const phone = body.phoneDeviceId ? devices.get(body.phoneDeviceId) : undefined;
    if (!phone || phone.kind !== 'phone') {
      writeJson(response, 404, { error: 'phone_not_registered' });
      return;
    }
    if (activeBindingsForPhone(phone.id).length >= FREE_ENTITLEMENT.maxBoundComputers) {
      writeJson(response, 409, { error: 'free_entitlement_computer_limit' });
      return;
    }
    const binding = findBindingByCode(body.code);
    if (!binding || binding.status !== 'pending') {
      writeJson(response, 404, { error: 'pairing_code_not_found' });
      return;
    }
    if (Date.parse(binding.expiresAt) < Date.now()) {
      writeJson(response, 410, { error: 'pairing_code_expired' });
      return;
    }
    binding.phoneDeviceId = phone.id;
    binding.status = 'claimed';
    binding.claimedAt = now();
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
    writeJson(response, 200, { binding });
    return;
  }

  if (method === 'POST' && url.pathname === '/api/messages/send') {
    const body = await readJson<{
      bindingId?: string;
      fromDeviceId?: string;
      toDeviceId?: string;
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
    const message: RelayMessage = {
      id: `msg_${randomUUID()}`,
      bindingId: binding.id,
      fromDeviceId: body.fromDeviceId,
      toDeviceId: body.toDeviceId,
      payload: body.payload ?? {},
      createdAt: now(),
    };
    const queue = messages.get(message.toDeviceId) ?? [];
    queue.push(message);
    messages.set(message.toDeviceId, queue);
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
  if (!code) {
    return undefined;
  }
  return [...bindings.values()].find((binding) => binding.code === code);
}

function isBindingParticipant(binding: Binding, deviceId: string | undefined): deviceId is string {
  return Boolean(deviceId && (deviceId === binding.daemonDeviceId || deviceId === binding.phoneDeviceId));
}

function makePairingCode(): string {
  return randomUUID().replaceAll('-', '').slice(0, 12).toUpperCase();
}

function now(): string {
  return new Date().toISOString();
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

server.listen(port, () => {
  console.log(`nudge relay listening on :${port}`);
});
