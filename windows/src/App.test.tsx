import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, test, vi } from "vitest";
import App from "./App";
import { api } from "./api";

vi.mock("./api", () => ({ api: {
  dashboard: vi.fn(), startOAuth: vi.fn(), refreshUsage: vi.fn(), setActive: vi.fn(), removeAccount: vi.fn(), exportAccounts: vi.fn(), importAccounts: vi.fn(), createProfile: vi.fn(), launchProfile: vi.fn(), removeProfile: vi.fn(), startGateway: vi.fn(), stopGateway: vi.fn(), setStartAtLogin: vi.fn(), checkUpdate: vi.fn(),
  createProvider: vi.fn(), removeProvider: vi.fn(), setActiveProvider: vi.fn(), addProviderAccount: vi.fn(), removeProviderAccount: vi.fn(), setActiveProviderAccount: vi.fn(), setAutoRoute: vi.fn(), records: vi.fn(), refreshThemes: vi.fn(), themePage: vi.fn(), setThemeSource: vi.fn(), addThemeSource: vi.fn(), installTheme: vi.fn(), installDreamSkin: vi.fn(), importLocalTheme: vi.fn(), applyTheme: vi.fn(), revertTheme: vi.fn(), uninstallTheme: vi.fn(), setAutoReapply: vi.fn(), setCodexExecutable: vi.fn(), desktopStatus: vi.fn(), updateDesktopSettings: vi.fn(),
} }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

const dashboard = { accounts: [{ id: "a1", email: "test@example.com", openaiAccountId: "org", planType: "plus", primaryUsedPercent: 25, secondaryUsedPercent: 70, primaryResetAt: null, secondaryResetAt: null, lastChecked: null, isActive: true, isSuspended: false, tokenExpired: false, organizationName: null }], profiles: [], providers: [], activeProviderId: null, themeState: { installed: [], appliedThemeId: null, autoReapply: false, codexExecutable: null, debugPort: null }, themeSources: [], autoRouteEnabled: false, autoRouteThreshold: 90, cost: { inputTokens: 1200, cachedInputTokens: 100, outputTokens: 50, estimatedUsd: .02, sessionCount: 2 }, gateway: null, startAtLogin: false };

beforeEach(() => { vi.clearAllMocks(); vi.mocked(api.dashboard).mockResolvedValue(dashboard); });

test("renders account usage and local cost", async () => {
  render(<App />);
  expect(screen.getByRole("img", { name: "codex-box" })).toBeInTheDocument();
  expect(await screen.findByText("test@example.com")).toBeInTheDocument();
  expect(screen.getByText("25%")).toBeInTheDocument();
  expect(screen.getByText("$0.02")).toBeInTheDocument();
});

test("creates a named isolated profile", async () => {
  vi.mocked(api.createProfile).mockResolvedValue({ id: "p1", name: "工作", accountId: "a1", codexHome: "C:\\profile", createdAt: new Date().toISOString() });
  render(<App />);
  const input = await screen.findByPlaceholderText("例如：工作账号");
  fireEvent.change(input, { target: { value: "工作" } });
  fireEvent.click(screen.getByRole("button", { name: "创建" }));
  await waitFor(() => expect(api.createProfile).toHaveBeenCalledWith("工作", "a1"));
});

test("renders only one bounded page for a large theme market", async () => {
  const items = Array.from({ length: 24 }, (_, index) => ({ id: `theme-${index}`, name: `主题 ${index}`, version: "1", author: null, description: null, license: null, tags: [], theme: "theme.json", preview: null, sourceBaseUrl: "https://example.com", sourceName: "测试源", isPack: false, declaredSha256: null, inlineColors: null, inlineAppearance: null }));
  vi.mocked(api.refreshThemes).mockResolvedValue({ items, total: 500, offset: 0, limit: 24, issues: [] });
  const { container } = render(<App />);
  fireEvent.click(screen.getByRole("button", { name: "主题" }));
  fireEvent.click(screen.getByRole("button", { name: "刷新市场" }));
  expect(await screen.findByText("主题 23")).toBeInTheDocument();
  expect(container.querySelectorAll(".theme-card")).toHaveLength(24);
  expect(screen.getByText("1 / 21")).toBeInTheDocument();
});
