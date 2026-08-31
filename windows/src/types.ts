export interface Account {
  id: string;
  email: string;
  openaiAccountId: string;
  planType: string;
  primaryUsedPercent: number;
  secondaryUsedPercent: number;
  primaryResetAt: string | null;
  secondaryResetAt: string | null;
  lastChecked: string | null;
  isActive: boolean;
  isSuspended: boolean;
  tokenExpired: boolean;
  organizationName: string | null;
}

export interface Profile { id: string; name: string; accountId: string | null; codexHome: string; createdAt: string }
export interface CostSummary { inputTokens: number; cachedInputTokens: number; outputTokens: number; estimatedUsd: number; sessionCount: number }
export interface GatewayStatus { baseUrl: string; apiKey: string; accountId: string; accountEmail: string }
export interface Dashboard { accounts: Account[]; profiles: Profile[]; cost: CostSummary; gateway: GatewayStatus | null; startAtLogin: boolean }
export interface StartedFlow { flowId: string; authUrl: string }
export interface UpdateInfo { version: string; downloadUrl: string; releaseUrl: string }
