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

export const FREE_ENTITLEMENT: Entitlement = {
  plan: 'free',
  maxBoundComputers: 1,
  maxTabsPerComputer: 1,
};
