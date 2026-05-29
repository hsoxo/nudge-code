import { spawn } from 'node:child_process';
import {
  createCipheriv,
  createDecipheriv,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  sign,
  verify,
  type KeyObject,
} from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { WebSocket } from 'ws';

interface DeviceResponse {
  device: { id: string };
}

interface BindingResponse {
  binding: {
    id: string;
    code: string;
    daemonDeviceId?: string;
    phoneDeviceId?: string;
  };
}

interface ChallengeResponse {
  challenge: { id: string; message: string };
}

interface RelayMessage {
  type: 'message';
  message: {
    fromDeviceId?: string;
    payload: {
      type: string;
      requestId?: string;
      ok?: boolean;
      data?: unknown;
      sessionId?: string;
      senderDeviceId?: string;
      recipientDeviceId?: string;
      messageType?: string;
      sequence?: string;
      nonceBase64?: string;
      ciphertextBase64?: string;
      senderEphemeralPublicKeyBase64?: string;
      transcriptSignatureBase64?: string;
      acceptedAt?: string;
    };
  };
}

interface E2ESession {
  sessionId: string;
  phoneDeviceId: string;
  daemonDeviceId: string;
  sendKey: Buffer;
  receiveKey: Buffer;
  nextSequence: bigint;
  highestReceived: bigint;
  encrypt(messageType: string, payload: unknown): Record<string, string>;
  decrypt(envelope: RelayMessage['message']['payload']): unknown;
}

interface SmokeContext {
  daemonPublicKey: string;
  daemonDeviceId: string;
  phoneDeviceId: string;
  phoneIdentity: { publicKey: string; privateKey: KeyObject };
}

const baseUrl = process.env.NUDGE_RELAY_SMOKE_URL ?? 'http://127.0.0.1:8787';
const nudgeBin = process.env.NUDGE_SMOKE_NUDGE_BIN ?? join(process.cwd(), '..', '..', 'target', 'debug', 'nudge');
const textEncoder = new TextEncoder();
const ed25519SpkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
const x25519SpkiPrefix = Buffer.from('302a300506032b656e032100', 'hex');

interface BindingResult {
  bindingId: string;
  daemonDeviceId: string;
  phoneDeviceId: string;
}

async function main(): Promise<void> {
  const tmp = await mkdtemp(join(tmpdir(), 'nudge-daemon-control-'));
  let env: NodeJS.ProcessEnv | undefined;
  try {
    env = {
      ...process.env,
      NUDGE_STATE_PATH: join(tmp, 'state', 'session.json'),
      NUDGE_RUNTIME_DIR: join(tmp, 'run'),
    };
    const daemonPublicKey = (await runNudge(env, ['device-public-key'])).trim();
    const seededState = await readSessionState(env);
    await writeSessionState(env, {
      ...seededState,
      entitlement: {
        plan: 'paid',
        max_bound_computers: 1,
        max_tabs_per_computer: 3,
        updated_at: 'smoke-seed',
      },
    });
    const phoneIdentity = generateSmokeIdentity();
    const binding = await bindThroughCli(env, phoneIdentity.publicKey);
    await assertRelayEntitlementPersisted(env);
    await runNudge(env, ['restart-tab']);

    await waitForDaemonRelay(env);

    const smokeContext: SmokeContext = {
      daemonPublicKey,
      daemonDeviceId: binding.daemonDeviceId,
      phoneDeviceId: binding.phoneDeviceId,
      phoneIdentity,
    };
    let phoneConnection = await connectEncryptedPhone(smokeContext, binding.bindingId);
    phoneConnection.websocket.send(JSON.stringify({
      toDeviceId: binding.daemonDeviceId,
      payload: phoneConnection.e2eSession.encrypt('get_state', { type: 'get_state', requestId: 'state-1' }),
    }));
    const stateResponse = await waitForEncryptedDaemonResponse(
      phoneConnection.websocket,
      phoneConnection.e2eSession,
      'state-1',
    );
    if (!stateResponse.ok) {
      throw new Error(`state response failed: ${JSON.stringify(stateResponse)}`);
    }

    phoneConnection.websocket.send(JSON.stringify({
      toDeviceId: binding.daemonDeviceId,
      payload: phoneConnection.e2eSession.encrypt('terminal_input', {
        type: 'terminal_input',
        requestId: 'input-1',
        tabId: 'default',
        text: 'echo NUDGE_RELAY_CONTROL',
        enter: true,
      }),
    }));
    const inputResponse = await waitForEncryptedDaemonResponse(
      phoneConnection.websocket,
      phoneConnection.e2eSession,
      'input-1',
    );
    if (!inputResponse.ok) {
      throw new Error(`input response failed: ${JSON.stringify(inputResponse)}`);
    }
    const liveOutput = await waitForEncryptedLiveOutput(
      phoneConnection.websocket,
      phoneConnection.e2eSession,
      'NUDGE_RELAY_CONTROL',
    );
    await assertEncryptedLiveAgentStatus(phoneConnection.websocket, phoneConnection.e2eSession);

    await sleep(300);
    const output = await runNudge(env, ['pty-output', '--max-bytes', '8192']);
    if (!output.includes('NUDGE_RELAY_CONTROL') && !liveOutput.includes('NUDGE_RELAY_CONTROL')) {
      throw new Error(`terminal output did not include relay input marker: ${output}`);
    }

    phoneConnection.websocket.close();
    await sleep(200);
    await waitForDaemonRelay(env);
    phoneConnection = await connectEncryptedPhone(smokeContext, binding.bindingId);
    phoneConnection.websocket.send(JSON.stringify({
      toDeviceId: binding.daemonDeviceId,
      payload: phoneConnection.e2eSession.encrypt('terminal_output', {
        type: 'terminal_output',
        requestId: 'replay-1',
        tabId: 'default',
        maxBytes: 8192,
      }),
    }));
    const replayResponse = await waitForEncryptedDaemonResponse(
      phoneConnection.websocket,
      phoneConnection.e2eSession,
      'replay-1',
    );
    const replayText = terminalOutputText(replayResponse.data);
    if (!replayResponse.ok || !replayText.includes('NUDGE_RELAY_CONTROL')) {
      throw new Error(`reconnected replay response did not include marker: ${JSON.stringify(replayResponse)}`);
    }

    phoneConnection.websocket.close();
    console.log(`daemon relay e2e control reconnect smoke passed binding=${binding.bindingId}`);
  } finally {
    if (env) {
      try {
        await runNudge(env, ['daemon', 'stop']);
      } catch {
        // daemon may not have started yet
      }
    }
    await rm(tmp, { recursive: true, force: true });
  }
}

async function bindThroughCli(env: NodeJS.ProcessEnv, phonePublicKey: string): Promise<BindingResult> {
  const bind = runNudge(env, [
    'bind',
    'phone',
    '--relay-url',
    baseUrl,
    '--wait',
    '--yes',
    '--timeout-seconds',
    '20',
  ]);
  const started = await waitForPendingBinding(env);
  const claimed = await postJson<BindingResponse>('/api/bind/claim', {
    code: started.code,
    phoneDeviceId: (await registerDevice('phone', phonePublicKey)).id,
  });
  await bind;
  const state = await readSessionState(env);
  if (state.binding?.status !== 'active') {
    throw new Error(`expected active binding after CLI bind, got ${JSON.stringify(state.binding)}`);
  }
  if (!state.binding.phone_public_key) {
    throw new Error('expected CLI bind to persist phone public key from relay confirm');
  }
  return {
    bindingId: started.bindingId,
    daemonDeviceId: started.daemonDeviceId,
    phoneDeviceId: claimed.binding.phoneDeviceId ?? state.binding.bound_phone_id,
  };
}

async function waitForPendingBinding(env: NodeJS.ProcessEnv): Promise<{
  bindingId: string;
  code: string;
  daemonDeviceId: string;
}> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const state = await readSessionState(env);
      if (state.binding?.status === 'pending') {
        return {
          bindingId: state.binding.binding_id,
          code: state.binding.code,
          daemonDeviceId: state.binding.daemon_device_id,
        };
      }
    } catch {
      // daemon may still be starting
    }
    await sleep(100);
  }
  throw new Error('timed out waiting for pending binding from CLI');
}

async function assertRelayEntitlementPersisted(env: NodeJS.ProcessEnv): Promise<void> {
  const state = await readSessionState(env);
  if (
    state.entitlement?.plan !== 'free' ||
    state.entitlement?.max_bound_computers !== 1 ||
    state.entitlement?.max_tabs_per_computer !== 1
  ) {
    throw new Error(`relay entitlement was not persisted in daemon state: ${JSON.stringify(state.entitlement)}`);
  }
}

async function readSessionState(env: NodeJS.ProcessEnv): Promise<{
  entitlement?: {
    plan?: string;
    max_bound_computers?: number;
    max_tabs_per_computer?: number;
    updated_at?: string;
  };
  binding?: {
    binding_id: string;
    code: string;
    daemon_device_id: string;
    status: string;
    bound_phone_id: string;
    phone_public_key?: string;
  };
}> {
  const statePath = env.NUDGE_STATE_PATH;
  if (!statePath) {
    throw new Error('NUDGE_STATE_PATH is required');
  }
  return JSON.parse(await readFile(statePath, 'utf8')) as {
    entitlement?: {
      plan?: string;
      max_bound_computers?: number;
      max_tabs_per_computer?: number;
      updated_at?: string;
    };
    binding?: {
      binding_id: string;
      code: string;
      daemon_device_id: string;
      status: string;
      bound_phone_id: string;
      phone_public_key?: string;
    };
  };
}

async function writeSessionState(env: NodeJS.ProcessEnv, state: unknown): Promise<void> {
  const statePath = env.NUDGE_STATE_PATH;
  if (!statePath) {
    throw new Error('NUDGE_STATE_PATH is required');
  }
  await writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
}

async function assertEncryptedLiveAgentStatus(websocket: WebSocket, session: E2ESession): Promise<void> {
  const status = await waitForEncryptedLiveAgentStatus(websocket, session);
  if (
    status.tabId !== 'default' ||
    status.agentStatus?.kind !== 'shell' ||
    status.agentStatus?.state !== 'running'
  ) {
    throw new Error(`unexpected live agent status payload: ${JSON.stringify(status)}`);
  }
}

async function connectEncryptedPhone(
  context: SmokeContext,
  bindingId: string,
): Promise<{ websocket: WebSocket; e2eSession: E2ESession }> {
  const websocket = await connectPhone(context.phoneDeviceId, bindingId, context.phoneIdentity.privateKey);
  const e2eSession = await openE2ESession({
    websocket,
    phoneDeviceId: context.phoneDeviceId,
    daemonDeviceId: context.daemonDeviceId,
    phoneIdentity: context.phoneIdentity,
    daemonPublicKey: context.daemonPublicKey,
  });
  return { websocket, e2eSession };
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

async function runNudge(env: NodeJS.ProcessEnv, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(nudgeBin, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('exit', (code) => {
      const out = Buffer.concat(stdout).toString('utf8');
      const err = Buffer.concat(stderr).toString('utf8');
      if (code !== 0) {
        reject(new Error(`nudge ${args.join(' ')} failed with ${code}: ${err || out}`));
        return;
      }
      resolve(out);
    });
  });
}

async function waitForDaemonRelay(env: NodeJS.ProcessEnv): Promise<void> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const status = await runNudge(env, ['daemon', 'status']);
      if (status.includes('relay_status=connected')) {
        return;
      }
    } catch {
      // daemon socket may not be ready yet
    }
    await sleep(200);
  }
  throw new Error('daemon did not connect to relay');
}

function generateSmokeIdentity(): { publicKey: string; privateKey: KeyObject } {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return {
    publicKey: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64'),
    privateKey,
  };
}

async function openE2ESession(input: {
  websocket: WebSocket;
  phoneDeviceId: string;
  daemonDeviceId: string;
  phoneIdentity: { publicKey: string; privateKey: KeyObject };
  daemonPublicKey: string;
}): Promise<E2ESession> {
  const sessionId = `e2e_smoke_${Date.now()}`;
  const phoneEphemeral = generateKeyPairSync('x25519');
  const phoneIdentityPublicKey = Buffer.from(input.phoneIdentity.publicKey, 'base64');
  const start = {
    type: 'e2e_handshake_start',
    sessionId,
    senderDeviceId: input.phoneDeviceId,
    recipientDeviceId: input.daemonDeviceId,
    senderIdentityPublicKeyBase64: phoneIdentityPublicKey.toString('base64'),
    senderEphemeralPublicKeyBase64: rawPublicKey(phoneEphemeral.publicKey).toString('base64'),
    transcriptSignatureBase64: '',
    createdAt: new Date().toISOString(),
  };
  const startTranscript = handshakeStartTranscript(start);
  start.transcriptSignatureBase64 = sign(null, startTranscript, input.phoneIdentity.privateKey).toString('base64');
  input.websocket.send(JSON.stringify({
    toDeviceId: input.daemonDeviceId,
    payload: start,
  }));

  const finishMessage = await waitForMessage(input.websocket, (message): message is RelayMessage => (
    message.type === 'message' &&
    message.message?.payload?.type === 'e2e_handshake_finish'
  ));
  const finish = finishMessage.message.payload;
  if (
    finish.sessionId !== sessionId ||
    finish.senderDeviceId !== input.daemonDeviceId ||
    finish.recipientDeviceId !== input.phoneDeviceId ||
    !finish.senderEphemeralPublicKeyBase64 ||
    !finish.transcriptSignatureBase64 ||
    !finish.acceptedAt
  ) {
    throw new Error(`invalid e2e handshake finish: ${JSON.stringify(finishMessage)}`);
  }
  const finishTranscript = handshakeFinishTranscript(
    startTranscript,
    Buffer.from(start.transcriptSignatureBase64, 'base64'),
    finish as Required<Pick<RelayMessage['message']['payload'], 'sessionId' | 'senderDeviceId' | 'recipientDeviceId' | 'senderEphemeralPublicKeyBase64' | 'acceptedAt'>>,
  );
  const daemonIdentityPublicKey = Buffer.from(input.daemonPublicKey, 'base64');
  if (!verify(null, finishTranscript, publicKeyObjectFromRawEd25519(daemonIdentityPublicKey), Buffer.from(finish.transcriptSignatureBase64, 'base64'))) {
    throw new Error('invalid e2e handshake finish signature');
  }

  const daemonEphemeralRaw = Buffer.from(finish.senderEphemeralPublicKeyBase64, 'base64');
  const sharedSecret = diffieHellman({
    privateKey: phoneEphemeral.privateKey,
    publicKey: publicKeyObjectFromRawX25519(daemonEphemeralRaw),
  });
  const [sendKey, receiveKey] = deriveDirectionalKeys({
    sessionId,
    sharedSecret,
    phoneEphemeralPublicKey: rawPublicKey(phoneEphemeral.publicKey),
    daemonEphemeralPublicKey: daemonEphemeralRaw,
  });
  return makeE2ESession({
    sessionId,
    phoneDeviceId: input.phoneDeviceId,
    daemonDeviceId: input.daemonDeviceId,
    sendKey,
    receiveKey,
  });
}

function makeE2ESession(input: {
  sessionId: string;
  phoneDeviceId: string;
  daemonDeviceId: string;
  sendKey: Buffer;
  receiveKey: Buffer;
}): E2ESession {
  return {
    ...input,
    nextSequence: 1n,
    highestReceived: 0n,
    encrypt(messageType: string, payload: unknown): Record<string, string> {
      const sequence = this.nextSequence;
      this.nextSequence += 1n;
      const nonce = sequenceNonce(sequence);
      const plaintext = Buffer.from(JSON.stringify(payload), 'utf8');
      const cipher = createCipheriv('chacha20-poly1305', this.sendKey, nonce, { authTagLength: 16 });
      cipher.setAAD(
        associatedData(
          this.sessionId,
          this.phoneDeviceId,
          this.daemonDeviceId,
          messageType,
          sequence,
          nonce,
        ),
        { plaintextLength: plaintext.length },
      );
      const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
      return {
        type: 'e2e_envelope',
        sessionId: this.sessionId,
        senderDeviceId: this.phoneDeviceId,
        recipientDeviceId: this.daemonDeviceId,
        messageType,
        sequence: sequence.toString(),
        nonceBase64: nonce.toString('base64'),
        ciphertextBase64: ciphertext.toString('base64'),
      };
    },
    decrypt(envelope: RelayMessage['message']['payload']): unknown {
      if (
        envelope.type !== 'e2e_envelope' ||
        envelope.sessionId !== this.sessionId ||
        envelope.senderDeviceId !== this.daemonDeviceId ||
        envelope.recipientDeviceId !== this.phoneDeviceId ||
        !envelope.messageType ||
        !envelope.sequence ||
        !envelope.nonceBase64 ||
        !envelope.ciphertextBase64
      ) {
        throw new Error(`invalid e2e envelope: ${JSON.stringify(envelope)}`);
      }
      const sequence = BigInt(envelope.sequence);
      if (sequence <= this.highestReceived) {
        throw new Error('e2e replay detected');
      }
      const nonce = Buffer.from(envelope.nonceBase64, 'base64');
      const ciphertextAndTag = Buffer.from(envelope.ciphertextBase64, 'base64');
      const ciphertext = ciphertextAndTag.subarray(0, -16);
      const tag = ciphertextAndTag.subarray(-16);
      const decipher = createDecipheriv('chacha20-poly1305', this.receiveKey, nonce, { authTagLength: 16 });
      decipher.setAAD(
        associatedData(
          envelope.sessionId,
          envelope.senderDeviceId,
          envelope.recipientDeviceId,
          envelope.messageType,
          sequence,
          nonce,
        ),
        { plaintextLength: ciphertext.length },
      );
      decipher.setAuthTag(tag);
      const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      this.highestReceived = sequence;
      return JSON.parse(plaintext.toString('utf8')) as unknown;
    },
  };
}

async function waitForEncryptedDaemonResponse(
  websocket: WebSocket,
  session: E2ESession,
  requestId: string,
): Promise<{ ok?: boolean; data?: unknown }> {
  while (true) {
    const message = await waitForMessage(websocket, (candidate): candidate is RelayMessage => (
      candidate.type === 'message' &&
      candidate.message?.payload?.type === 'e2e_envelope'
    ));
    const payload = session.decrypt(message.message.payload) as { type?: string; requestId?: string; ok?: boolean; data?: unknown };
    if (payload.type === 'daemon_response' && payload.requestId === requestId) {
      return payload;
    }
  }
}

async function waitForEncryptedLiveOutput(
  websocket: WebSocket,
  session: E2ESession,
  expectedText: string,
): Promise<string> {
  const deadline = Date.now() + 10_000;
  let combined = '';
  while (Date.now() < deadline) {
    const message = await waitForMessage(websocket, (candidate): candidate is RelayMessage => (
      candidate.type === 'message' &&
      candidate.message?.payload?.type === 'e2e_envelope'
    ));
    const payload = session.decrypt(message.message.payload) as {
      type?: string;
      ok?: boolean;
      data?: { bytesBase64?: string; text?: string };
    };
    if (payload.type !== 'daemon_response' || payload.ok !== true) {
      continue;
    }
    if (payload.data?.bytesBase64) {
      combined += Buffer.from(payload.data.bytesBase64, 'base64').toString('utf8');
    }
    if (payload.data?.text) {
      combined += payload.data.text;
    }
    if (combined.includes(expectedText)) {
      return combined;
    }
  }
  throw new Error(`timed out waiting for encrypted live output containing ${expectedText}`);
}

async function waitForEncryptedLiveAgentStatus(
  websocket: WebSocket,
  session: E2ESession,
): Promise<{ tabId?: string; agentStatus?: { kind?: string; state?: string } }> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const message = await waitForMessage(websocket, (candidate): candidate is RelayMessage => (
      candidate.type === 'message' &&
      candidate.message?.payload?.type === 'e2e_envelope'
    ));
    const payload = session.decrypt(message.message.payload) as {
      type?: string;
      ok?: boolean;
      data?: { tabId?: string; agentStatus?: { kind?: string; state?: string } };
    };
    if (payload.type === 'daemon_response' && payload.ok === true && payload.data?.agentStatus) {
      return payload.data;
    }
  }
  throw new Error('timed out waiting for encrypted live agent status');
}

function terminalOutputText(data: unknown): string {
  if (!data || typeof data !== 'object') {
    return '';
  }
  const output = data as { bytesBase64?: unknown; text?: unknown };
  if (typeof output.bytesBase64 === 'string') {
    return Buffer.from(output.bytesBase64, 'base64').toString('utf8');
  }
  if (typeof output.text === 'string') {
    return output.text;
  }
  return '';
}

function deriveDirectionalKeys(input: {
  sessionId: string;
  sharedSecret: Buffer;
  phoneEphemeralPublicKey: Buffer;
  daemonEphemeralPublicKey: Buffer;
}): [Buffer, Buffer] {
  const salt = Buffer.concat([
    Buffer.from(input.sessionId, 'utf8'),
    input.phoneEphemeralPublicKey,
    input.daemonEphemeralPublicKey,
  ]);
  return [
    Buffer.from(hkdfSync('sha256', input.sharedSecret, salt, Buffer.from('nudge e2e phone-to-daemon v1'), 32)),
    Buffer.from(hkdfSync('sha256', input.sharedSecret, salt, Buffer.from('nudge e2e daemon-to-phone v1'), 32)),
  ];
}

function sequenceNonce(sequence: bigint): Buffer {
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(sequence, 4);
  return nonce;
}

function associatedData(
  sessionId: string,
  senderDeviceId: string,
  recipientDeviceId: string,
  messageType: string,
  sequence: bigint,
  nonce: Buffer,
): Buffer {
  const sequenceBytes = Buffer.alloc(8);
  sequenceBytes.writeBigUInt64BE(sequence);
  return joinTranscriptFields([
    Buffer.from('nudge.e2e.envelope.v1', 'utf8'),
    Buffer.from(sessionId, 'utf8'),
    Buffer.from(senderDeviceId, 'utf8'),
    Buffer.from(recipientDeviceId, 'utf8'),
    Buffer.from(messageType, 'utf8'),
    sequenceBytes,
    nonce,
  ]);
}

function handshakeStartTranscript(start: {
  sessionId: string;
  senderDeviceId: string;
  recipientDeviceId: string;
  senderIdentityPublicKeyBase64: string;
  senderEphemeralPublicKeyBase64: string;
  createdAt: string;
}): Buffer {
  return joinTranscriptFields([
    Buffer.from('nudge.e2e.handshake.start.v1', 'utf8'),
    Buffer.from(start.sessionId, 'utf8'),
    Buffer.from(start.senderDeviceId, 'utf8'),
    Buffer.from(start.recipientDeviceId, 'utf8'),
    Buffer.from(start.senderIdentityPublicKeyBase64, 'base64'),
    Buffer.from(start.senderEphemeralPublicKeyBase64, 'base64'),
    Buffer.from(start.createdAt, 'utf8'),
  ]);
}

function handshakeFinishTranscript(
  startTranscript: Buffer,
  startSignature: Buffer,
  finish: {
    sessionId: string;
    senderDeviceId: string;
    recipientDeviceId: string;
    senderEphemeralPublicKeyBase64: string;
    acceptedAt: string;
  },
): Buffer {
  return joinTranscriptFields([
    Buffer.from('nudge.e2e.handshake.finish.v1', 'utf8'),
    startTranscript,
    startSignature,
    Buffer.from(finish.sessionId, 'utf8'),
    Buffer.from(finish.senderDeviceId, 'utf8'),
    Buffer.from(finish.recipientDeviceId, 'utf8'),
    Buffer.from(finish.senderEphemeralPublicKeyBase64, 'base64'),
    Buffer.from(finish.acceptedAt, 'utf8'),
  ]);
}

function joinTranscriptFields(fields: Buffer[]): Buffer {
  return Buffer.concat(fields.flatMap((field, index) => (
    index === fields.length - 1 ? [field] : [field, Buffer.from([0])]
  )));
}

function rawPublicKey(publicKey: KeyObject): Buffer {
  return publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
}

function publicKeyObjectFromRawEd25519(rawPublicKey: Buffer): KeyObject {
  return createPublicKey({
    key: Buffer.concat([ed25519SpkiPrefix, rawPublicKey]),
    format: 'der',
    type: 'spki',
  });
}

function publicKeyObjectFromRawX25519(rawPublicKey: Buffer): KeyObject {
  return createPublicKey({
    key: Buffer.concat([x25519SpkiPrefix, rawPublicKey]),
    format: 'der',
    type: 'spki',
  });
}

async function connectPhone(deviceId: string, bindingId: string, privateKey: KeyObject): Promise<WebSocket> {
  const wsUrl = await signedPhoneWebSocketUrl(deviceId, bindingId, privateKey);
  const websocket = new WebSocket(wsUrl);
  await new Promise<void>((resolve, reject) => {
    websocket.once('open', () => resolve());
    websocket.once('error', reject);
  });
  await waitForMessage(websocket, (message) => message.type === 'connected');
  return websocket;
}

async function signedPhoneWebSocketUrl(deviceId: string, bindingId: string, privateKey: KeyObject): Promise<string> {
  const url = new URL(`${baseUrl.replace(/^http/, 'ws')}/ws/mobile`);
  const challenge = await issueSocketChallenge(deviceId, bindingId);
  url.searchParams.set('deviceId', deviceId);
  url.searchParams.set('bindingId', bindingId);
  url.searchParams.set('authChallengeId', challenge.id);
  url.searchParams.set('authChallengeSignature', sign(null, Buffer.from(challenge.message), privateKey).toString('base64'));
  return url.toString();
}

async function issueSocketChallenge(deviceId: string, bindingId: string): Promise<ChallengeResponse['challenge']> {
  const response = await postJson<ChallengeResponse>('/api/ws/challenge', { deviceId, bindingId });
  return response.challenge;
}

function waitForMessage<T extends Record<string, any>>(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => message is T,
): Promise<T>;
function waitForMessage(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => boolean,
): Promise<Record<string, any>>;
function waitForMessage(
  websocket: WebSocket,
  predicate: (message: Record<string, any>) => boolean,
): Promise<Record<string, any>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      websocket.off('message', onMessage);
      reject(new Error('timed out waiting for websocket message'));
    }, 10000);
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
