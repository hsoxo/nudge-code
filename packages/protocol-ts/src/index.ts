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
}

export interface SessionState {
  tabs: Tab[];
  entitlement: Entitlement;
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

export const FREE_ENTITLEMENT: Entitlement = {
  plan: 'free',
  maxBoundComputers: 1,
  maxTabsPerComputer: 1,
};
