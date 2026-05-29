import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

interface ReadinessResponse {
  ok: boolean;
  config: {
    hostedMode: boolean;
    statePersistence: boolean;
    host: string;
    requireWebSocketSignature: boolean;
    requireWebSocketChallenge: boolean;
    requireE2EPayload: boolean;
    disableHttpMessageEndpoints: boolean;
  };
  warnings: string[];
}

const relayBin = join(process.cwd(), 'dist', 'index.js');
const port = Number.parseInt(process.env.NUDGE_RELAY_READYZ_PORT ?? '8798', 10);
const baseUrl = `http://127.0.0.1:${port}`;

async function main(): Promise<void> {
  const tmp = await mkdtemp(join(tmpdir(), 'nudge-relay-readyz-'));
  try {
    await withRelay({}, async () => {
      const ready = await getJson<ReadinessResponse>('/readyz');
      assertWarning(ready, 'relay_state_not_persistent');
      assertWarning(ready, 'websocket_signature_not_required');
      assertWarning(ready, 'websocket_challenge_not_required');
      assertWarning(ready, 'legacy_http_messages_enabled');
      assertWarning(ready, 'e2e_payload_not_required');
    });

    await withRelay({
      NUDGE_RELAY_STATE_PATH: join(tmp, 'relay-state.json'),
      NUDGE_RELAY_HOSTED_MODE: '1',
    }, async () => {
      const ready = await getJson<ReadinessResponse>('/readyz');
      if (!ready.config.hostedMode) {
        throw new Error(`expected hosted mode config, got ${JSON.stringify(ready)}`);
      }
      if (ready.config.host !== '127.0.0.1') {
        throw new Error(`expected configured relay host, got ${JSON.stringify(ready)}`);
      }
      if (!ready.config.statePersistence) {
        throw new Error(`expected persistent state config, got ${JSON.stringify(ready)}`);
      }
      if (
        !ready.config.requireWebSocketSignature ||
        !ready.config.requireWebSocketChallenge ||
        !ready.config.requireE2EPayload ||
        !ready.config.disableHttpMessageEndpoints
      ) {
        throw new Error(`expected hosted hardening config, got ${JSON.stringify(ready)}`);
      }
      for (const warning of [
        'relay_state_not_persistent',
        'websocket_signature_not_required',
        'websocket_challenge_not_required',
        'legacy_http_messages_enabled',
        'e2e_payload_not_required',
      ]) {
        if (ready.warnings.includes(warning)) {
          throw new Error(`unexpected hosted warning ${warning}: ${JSON.stringify(ready)}`);
        }
      }
    });

    console.log('relay readyz smoke passed');
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
}

async function withRelay(env: NodeJS.ProcessEnv, callback: () => Promise<void>): Promise<void> {
  const relay = await startRelay(env);
  try {
    await callback();
  } finally {
    await stopRelay(relay);
  }
}

async function startRelay(env: NodeJS.ProcessEnv): Promise<ChildProcess> {
  const relay = spawn(process.execPath, [relayBin], {
    env: {
      ...process.env,
      ...env,
      NUDGE_RELAY_PORT: String(port),
      NUDGE_RELAY_HOST: '127.0.0.1',
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  relay.stderr?.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8');
  });
  relay.on('exit', (code) => {
    if (code !== null && code !== 0) {
      stderr += `relay exited with ${code}`;
    }
  });
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (relay.exitCode !== null) {
      throw new Error(stderr || `relay exited with ${relay.exitCode}`);
    }
    try {
      const health = await getJson<{ ok: boolean }>('/healthz');
      if (health.ok) {
        return relay;
      }
    } catch {
      // relay may still be binding the port
    }
    await sleep(100);
  }
  throw new Error(`relay did not start: ${stderr}`);
}

async function stopRelay(relay: ChildProcess): Promise<void> {
  if (relay.exitCode !== null) {
    return;
  }
  relay.kill('SIGTERM');
  await new Promise<void>((resolve) => {
    relay.once('exit', () => resolve());
    setTimeout(() => {
      if (relay.exitCode === null) {
        relay.kill('SIGKILL');
      }
      resolve();
    }, 2000);
  });
}

async function getJson<T = unknown>(path: string): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`);
  if (!response.ok) {
    throw new Error(`${path} failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as T;
}

function assertWarning(ready: ReadinessResponse, warning: string): void {
  if (!ready.warnings.includes(warning)) {
    throw new Error(`expected warning ${warning}, got ${JSON.stringify(ready)}`);
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
