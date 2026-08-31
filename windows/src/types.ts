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
export interface GatewayStatus { baseUrl: string; apiKey: string; accountId: string; accountEmail: string; routeModel: string | null }
export interface ProviderAccount { id: string; label: string }
export interface Provider { id: string; label: string; kind: "openAiCompatible" | "openRouter"; baseUrl: string; model: string; accounts: ProviderAccount[]; activeAccountId: string | null }
export interface ThemeSource { id: string; name: string; baseUrl: string; enabled: boolean; format: string }
export interface ThemeColors { background?: string; panel?: string; panelAlt?: string; accent?: string; accentAlt?: string; secondary?: string; highlight?: string; text?: string; muted?: string; line?: string }
export interface ThemeListing { id: string; name: string; version: string; author: string | null; description: string | null; license: string | null; tags: string[]; theme: string; preview: string | null; sourceBaseUrl: string; sourceName: string; isPack: boolean; declaredSha256: string | null; inlineColors: ThemeColors | null; inlineAppearance: string | null }
export interface InstalledTheme { id: string; name: string; version: string; installedAt: string; themeSha256: string; imageSha256: string | null; hasImage: boolean }
export interface ThemeState { installed: InstalledTheme[]; appliedThemeId: string | null; autoReapply: boolean; codexExecutable: string | null; debugPort: number | null }
export interface ThemePage { items: ThemeListing[]; total: number; offset: number; limit: number; issues: string[] }
export interface ThreadPreset { model: string; reasoningEffort: string; serviceTier: string; contextWindow: number }
export interface DesktopStatus { connected: boolean; target: string; conversationId: string | null; preset: ThreadPreset; codexExecutable: string | null; debugPort: number | null }
export interface SessionRecord { sessionId: string; modelId: string; startedAt: string | null; lastActivityAt: string | null; archived: boolean; totalTokens: number; fileName: string }
export interface ModelRecord { modelId: string; sessionCount: number; lastSeenAt: string | null }
export interface RecordsSnapshot { sessions: SessionRecord[]; models: ModelRecord[]; warnings: string[] }
export interface Dashboard { accounts: Account[]; profiles: Profile[]; cost: CostSummary; gateway: GatewayStatus | null; startAtLogin: boolean; providers: Provider[]; activeProviderId: string | null; themeState: ThemeState; themeSources: ThemeSource[]; autoRouteEnabled: boolean; autoRouteThreshold: number }
export interface StartedFlow { flowId: string; authUrl: string }
export interface UpdateInfo { version: string; downloadUrl: string; releaseUrl: string }
