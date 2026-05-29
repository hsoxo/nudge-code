import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import pg from 'pg';

export type DeviceKind = 'daemon' | 'phone';
export type DeviceStatus = 'active' | 'revoked';
export type BindingStatus = 'pending' | 'claimed' | 'active' | 'revoked';

export interface Device {
  id: string;
  kind: DeviceKind;
  publicKey: string;
  createdAt: string;
  status?: DeviceStatus;
  revokedAt?: string;
}

export interface Binding {
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

export interface PersistedRelayState {
  version: 1;
  devices: Device[];
  bindings: Binding[];
  updatedAt: string;
}

export interface RelayStateStore {
  readonly kind: 'memory' | 'file' | 'postgres';
  load(): Promise<PersistedRelayState | undefined>;
  save(state: PersistedRelayState): Promise<void>;
  close?(): Promise<void>;
}

export function createRelayStateStore(input: {
  statePath?: string;
  databaseUrl?: string;
}): RelayStateStore {
  if (input.databaseUrl) {
    return new PostgresRelayStateStore(input.databaseUrl);
  }
  if (input.statePath) {
    return new FileRelayStateStore(input.statePath);
  }
  return new MemoryRelayStateStore();
}

class MemoryRelayStateStore implements RelayStateStore {
  readonly kind = 'memory' as const;

  async load(): Promise<PersistedRelayState | undefined> {
    return undefined;
  }

  async save(_state: PersistedRelayState): Promise<void> {
    // Memory mode intentionally does not persist across restarts.
  }
}

class FileRelayStateStore implements RelayStateStore {
  readonly kind = 'file' as const;

  constructor(private readonly statePath: string) {}

  async load(): Promise<PersistedRelayState | undefined> {
    if (!existsSync(this.statePath)) {
      return undefined;
    }
    const parsed = JSON.parse(readFileSync(this.statePath, 'utf8')) as Partial<PersistedRelayState>;
    const state = normalizeRelayState(parsed, `relay state file ${this.statePath}`);
    chmodSync(this.statePath, 0o600);
    return state;
  }

  async save(state: PersistedRelayState): Promise<void> {
    mkdirSync(dirname(this.statePath), { recursive: true });
    const tmpPath = `${this.statePath}.${process.pid}.tmp`;
    writeFileSync(tmpPath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    chmodSync(tmpPath, 0o600);
    renameSync(tmpPath, this.statePath);
    chmodSync(this.statePath, 0o600);
  }
}

class PostgresRelayStateStore implements RelayStateStore {
  readonly kind = 'postgres' as const;
  private readonly pool: pg.Pool;

  constructor(databaseUrl: string) {
    this.pool = new pg.Pool({ connectionString: databaseUrl });
  }

  async load(): Promise<PersistedRelayState | undefined> {
    await this.ensureSchema();
    const result = await this.pool.query<{ state: unknown }>(
      'SELECT state FROM relay_state WHERE id = $1',
      ['default'],
    );
    const row = result.rows[0];
    if (!row) {
      return undefined;
    }
    return normalizeRelayState(row.state, 'postgres relay_state.default');
  }

  async save(state: PersistedRelayState): Promise<void> {
    await this.ensureSchema();
    await this.pool.query(
      `INSERT INTO relay_state (id, state, updated_at)
       VALUES ($1, $2::jsonb, NOW())
       ON CONFLICT (id)
       DO UPDATE SET state = EXCLUDED.state, updated_at = NOW()`,
      ['default', JSON.stringify(state)],
    );
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  private async ensureSchema(): Promise<void> {
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS relay_state (
        id text PRIMARY KEY,
        state jsonb NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT NOW()
      )
    `);
  }
}

export function normalizeRelayState(value: unknown, source: string): PersistedRelayState {
  if (!value || typeof value !== 'object') {
    throw new Error(`unsupported ${source} format`);
  }
  const parsed = value as Partial<PersistedRelayState>;
  if (parsed.version !== 1 || !Array.isArray(parsed.devices) || !Array.isArray(parsed.bindings)) {
    throw new Error(`unsupported ${source} format`);
  }
  for (const device of parsed.devices) {
    if (!isPersistedDevice(device)) {
      throw new Error(`invalid relay device in ${source}`);
    }
  }
  for (const binding of parsed.bindings) {
    if (!isPersistedBinding(binding)) {
      throw new Error(`invalid relay binding in ${source}`);
    }
  }
  return {
    version: 1,
    devices: parsed.devices.map((device) => ({
      ...device,
      status: device.status ?? 'active',
    })),
    bindings: parsed.bindings,
    updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : new Date().toISOString(),
  };
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
    typeof device.createdAt === 'string' &&
    (device.status === undefined || device.status === 'active' || device.status === 'revoked') &&
    (device.revokedAt === undefined || typeof device.revokedAt === 'string')
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
