import { WebSocket } from 'ws';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: { id: string; code: string };
}

const baseUrl = process.env.NUDGE_RELAY_SMOKE_URL ?? 'http://127.0.0.1:8787';

async function main(): Promise<void> {
  const daemon = await registerDevice('daemon', 'smoke-daemon-key');
  const phone = await registerDevice('phone', 'smoke-phone-key');
  const binding = await postJson<BindingResponse>('/api/bind/start', { daemonDeviceId: daemon.id });
  await postJson('/api/bind/claim', { code: binding.binding.code, phoneDeviceId: phone.id });
  await postJson('/api/bind/confirm', { bindingId: binding.binding.id, daemonDeviceId: daemon.id });

  const daemonSocket = await connectSocket('daemon', daemon.id, binding.binding.id);
  const phoneSocket = await connectSocket('mobile', phone.id, binding.binding.id);

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

  daemonSocket.close();
  phoneSocket.close();
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

async function connectSocket(kind: 'daemon' | 'mobile', deviceId: string, bindingId: string): Promise<WebSocket> {
  const wsUrl = `${baseUrl.replace(/^http/, 'ws')}/ws/${kind}?deviceId=${deviceId}&bindingId=${bindingId}`;
  const websocket = new WebSocket(wsUrl);
  await new Promise<void>((resolve, reject) => {
    websocket.once('open', () => resolve());
    websocket.once('error', reject);
  });
  await waitForMessage(websocket, (message) => message.type === 'connected');
  return websocket;
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
