import { invoke } from "@tauri-apps/api/core";
import type { Account, Dashboard, GatewayStatus, Profile, StartedFlow, UpdateInfo } from "./types";

export const api = {
  dashboard: () => invoke<Dashboard>("get_dashboard"),
  startOAuth: () => invoke<StartedFlow>("start_oauth"),
  completeOAuth: (flowId: string, callback: string) => invoke<Account>("complete_oauth", { flowId, callback }),
  refreshUsage: (accountId: string) => invoke<Account>("refresh_usage", { accountId }),
  setActive: (accountId: string) => invoke<void>("set_active_account", { accountId }),
  removeAccount: (accountId: string) => invoke<void>("remove_account", { accountId }),
  createProfile: (name: string, accountId?: string) => invoke<Profile>("create_profile", { name, accountId: accountId || null }),
  launchProfile: (profileId: string) => invoke<void>("launch_profile", { profileId }),
  removeProfile: (profileId: string) => invoke<void>("remove_profile", { profileId }),
  startGateway: () => invoke<GatewayStatus>("start_gateway"),
  stopGateway: () => invoke<void>("stop_gateway"),
  setStartAtLogin: (enabled: boolean) => invoke<void>("set_start_at_login", { enabled }),
  checkUpdate: () => invoke<UpdateInfo | null>("check_update"),
};
