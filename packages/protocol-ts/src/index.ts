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
}

export interface SessionState {
  tabs: Tab[];
  entitlement: Entitlement;
  phoneProfile?: PhoneProfile;
}

export interface DaemonStatus {
  socketPath: string;
  statePath: string;
  connectedClients: number;
  uptimeSeconds: number;
  tabs: number;
  plan: EntitlementPlan;
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

export const FREE_ENTITLEMENT: Entitlement = {
  plan: 'free',
  maxBoundComputers: 1,
  maxTabsPerComputer: 1,
};
