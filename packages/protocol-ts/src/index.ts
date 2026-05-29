export type EntitlementPlan = 'free' | 'paid';

export interface Entitlement {
  plan: EntitlementPlan;
  maxBoundComputers: number;
  maxTabsPerComputer: number;
}

export interface Tab {
  id: string;
  title: string;
  status: 'running' | 'exited' | 'needs_attention' | 'needs_restart';
  widthMode: 'computer' | 'phone';
  rows: number;
  cols: number;
  agentStatus?: AgentStatus;
}

export type AgentKind = 'claude' | 'codex' | 'opencode' | 'openclaw' | 'shell' | 'unknown';
export type AgentInteractionState =
  | 'running'
  | 'idle'
  | 'waiting_for_input'
  | 'needs_approval'
  | 'needs_attention'
  | 'exited';

export interface AgentStatus {
  kind: AgentKind;
  state: AgentInteractionState;
  confidence: number;
  source: 'process' | 'screen' | 'title' | 'heuristic' | 'unknown';
}

export interface SessionState {
  tabs: Tab[];
  entitlement: Entitlement;
  phoneProfile?: PhoneProfile;
  binding?: BindingState;
}

export interface DaemonStatus {
  socketPath: string;
  statePath: string;
  connectedClients: number;
  uptimeSeconds: number;
  tabs: number;
  plan: EntitlementPlan;
  relayStatus: 'unbound' | 'connecting' | 'connected' | 'disconnected' | 'error';
  relayUrl: string;
  relayBindingId: string;
  relayLastError: string;
  relayConnectedAt: string;
  relayLastMessageAt: string;
}

export interface Ack {
  message: string;
}

export interface ProtocolError {
  code: string;
  message: string;
}

export interface TerminalInput {
  tabId: string;
  data: Uint8Array;
}

export interface TerminalOutputRequest {
  tabId: string;
  maxBytes: number;
}

export interface TerminalOutput {
  tabId: string;
  data: Uint8Array;
}

export interface TerminalSnapshotRequest {
  tabId: string;
}

export interface TerminalSnapshot {
  tabId: string;
  rows: number;
  cols: number;
  text: string;
  formatted: Uint8Array;
}

export interface TerminalRenderRequest {
  tabId: string;
}

export interface TerminalRender {
  tabId: string;
  rows: number;
  cols: number;
  frame: Uint8Array;
  widthMode: 'computer' | 'phone';
}

export interface PhoneProfile {
  rows: number;
  cols: number;
}

export type BindingStatus = 'pending' | 'active' | 'revoked';

export interface BindingState {
  relayUrl: string;
  daemonDeviceId: string;
  bindingId: string;
  code: string;
  expiresAt: string;
  status: BindingStatus;
  boundPhoneId?: string;
}

export interface SetPhoneProfile {
  rows: number;
  cols: number;
}

export interface SetWidthMode {
  tabId: string;
  mode: 'computer' | 'phone';
  computerRows: number;
  computerCols: number;
}

export interface CreateTab {
  title: string;
}

export interface RenameTab {
  tabId: string;
  title: string;
}

export interface CloseTab {
  tabId: string;
}

export interface ResizeTab {
  tabId: string;
  rows: number;
  cols: number;
}

export interface RestartTab {
  tabId: string;
}

export interface E2EHandshakeStart {
  sessionId: string;
  senderDeviceId: string;
  recipientDeviceId: string;
  senderIdentityPublicKey: Uint8Array;
  senderEphemeralPublicKey: Uint8Array;
  transcriptSignature: Uint8Array;
  createdAt: string;
}

export interface E2EHandshakeFinish {
  sessionId: string;
  senderDeviceId: string;
  recipientDeviceId: string;
  senderEphemeralPublicKey: Uint8Array;
  transcriptSignature: Uint8Array;
  acceptedAt: string;
}

export interface E2EEncryptedEnvelope {
  sessionId: string;
  senderDeviceId: string;
  recipientDeviceId: string;
  messageType: string;
  sequence: bigint;
  nonce: Uint8Array;
  ciphertext: Uint8Array;
}

export const FREE_ENTITLEMENT: Entitlement = {
  plan: 'free',
  maxBoundComputers: 1,
  maxTabsPerComputer: 1,
};
