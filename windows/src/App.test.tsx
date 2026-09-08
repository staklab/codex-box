import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, test, vi } from "vitest";
import App from "./App";
import { api } from "./api";

vi.mock("./api", () => ({ api: {
  dashboard: vi.fn(), startOAuth: vi.fn(), refreshUsage: vi.fn(), setActive: vi.fn(), removeAccount: vi.fn(), exportAccounts: vi.fn(), importAccounts: vi.fn(), createProfile: vi.fn(), launchProfile: vi.fn(), removeProfile: vi.fn(), startGateway: vi.fn(), stopGateway: vi.fn(), setStartAtLogin: vi.fn(), checkUpdate: vi.fn(), downloadUpdate: vi.fn(), installUpdate: vi.fn(),
  createProvider: vi.fn(), removeProvider: vi.fn(), setActiveProvider: vi.fn(), addProviderAccount: vi.fn(), removeProviderAccount: vi.fn(), setActiveProviderAccount: vi.fn(), setAutoRoute: vi.fn(), records: vi.fn(), refreshThemes: vi.fn(), themePage: vi.fn(), setThemeSource: vi.fn(), addThemeSource: vi.fn(), installTheme: vi.fn(), installAndApplyTheme: vi.fn(), installDreamSkin: vi.fn(), installAndApplyDreamSkin: vi.fn(), importLocalTheme: vi.fn(), applyTheme: vi.fn(), revertTheme: vi.fn(), uninstallTheme: vi.fn(), setAutoReapply: vi.fn(), setCodexExecutable: vi.fn(), desktopStatus: vi.fn(), updateDesktopSettings: vi.fn(), contextInfo: vi.fn(), createContextBranch: vi.fn(),
} }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

const dashboard = { accounts: [{ id: "a1", email: "test@example.com", openaiAccountId: "org", planType: "plus", primaryUsedPercent: 25, secondaryUsedPercent: 70, primaryResetAt: null, secondaryResetAt: null, lastChecked: null, isActive: true, isSuspended: false, tokenExpired: false, organizationName: null }], profiles: [], providers: [], activeProviderId: null, themeState: { installed: [], appliedThemeId: null, autoReapply: false, codexExecutable: null, debugPort: null }, themeSources: [], autoRouteEnabled: false, autoRouteThreshold: 90, cost: { inputTokens: 1200, cachedInputTokens: 100, outputTokens: 50, estimatedUsd: .02, sessionCount: 2 }, gateway: null, startAtLogin: false };

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(api.contextInfo).mockResolvedValue({maximum:872000, percent:95, configured:null});
  vi.mocked(api.dashboard).mockResolvedValue(dashboard);
  vi.mocked(api.desktopStatus).mockResolvedValue({ connected: false, target: "已识别，等待换肤连接", conversationId: null, preset: { model: "gpt-5.6-sol", reasoningEffort: "medium", serviceTier: "flex", contextWindow: 272000 }, codexExecutable: "C:\\Program Files\\ChatGPT\\ChatGPT.exe", debugPort: null });
  vi.mocked(api.checkUpdate).mockResolvedValue(null);
});

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

test("keeps destructive confirmation inside the app before removing an account", async () => {
  vi.mocked(api.removeAccount).mockResolvedValue();
  render(<App />);
  await screen.findByText("test@example.com");
  fireEvent.click(screen.getByRole("button", { name: "移除" }));
  expect(screen.getByRole("dialog", { name: "移除这个账号？" })).toBeInTheDocument();
  expect(api.removeAccount).not.toHaveBeenCalled();
  fireEvent.click(await screen.findByRole("button", { name: "确认" }));
  await waitFor(() => expect(api.removeAccount).toHaveBeenCalledWith("a1"));
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
  fireEvent.click(screen.getAllByRole("button", { name: "安装并应用" }).find(button => !button.hasAttribute("disabled"))!);
  fireEvent.click(await screen.findByRole("button", { name: "确认" }));
  await waitFor(() => expect(api.installAndApplyTheme).toHaveBeenCalledWith("theme-0", "测试源", true));
  fireEvent.click(screen.getByRole("button", { name: "账号" }));
  fireEvent.click(screen.getByRole("button", { name: "主题" }));
  expect(container.querySelectorAll(".theme-card")).toHaveLength(24);
  expect(api.refreshThemes).toHaveBeenCalledTimes(1);
});

test("automatically displays the detected Codex Desktop path", async () => {
  render(<App />);
  fireEvent.click(screen.getByRole("button", { name: "桌面" }));
  expect(await screen.findByDisplayValue("C:\\Program Files\\ChatGPT\\ChatGPT.exe")).toBeInTheDocument();
  expect(screen.getByText("已识别，等待换肤连接")).toBeInTheDocument();
});

test("downloads first and asks again before installing the update", async () => {
  vi.mocked(api.checkUpdate).mockResolvedValue({ version: "1.2.13", size: 12 * 1024 * 1024 });
  vi.mocked(api.downloadUpdate).mockResolvedValue({ version: "1.2.13" });
  vi.mocked(api.installUpdate).mockResolvedValue();
  render(<App />);
  await screen.findByText("test@example.com");
  fireEvent.click(screen.getByRole("button", { name: "检查更新" }));
  expect(await screen.findByRole("dialog", { name: "发现新版本 v1.2.13" })).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "后台下载" }));
  await waitFor(() => expect(api.downloadUpdate).toHaveBeenCalledTimes(1));
  expect(await screen.findByRole("dialog", { name: "安装 v1.2.13 并重启？" })).toBeInTheDocument();
  expect(api.installUpdate).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "稍后" }));
  expect(await screen.findByRole("button", { name: "安装并重启" })).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "安装并重启" }));
  const restartDialog = await screen.findByRole("dialog", { name: "安装 v1.2.13 并重启？" });
  fireEvent.click(within(restartDialog).getByRole("button", { name: "安装并重启" }));
  await waitFor(() => expect(api.installUpdate).toHaveBeenCalledTimes(1));
});

test("checks GitHub automatically after startup", async () => {
  render(<App />);
  await waitFor(() => expect(api.checkUpdate).toHaveBeenCalledTimes(1), { timeout: 2500 });
});

for (const connected of [false, true]) {
  test(`换肤检查真实连接而不是缓存端口：${connected}`, async () => {
    vi.mocked(api.dashboard).mockResolvedValue({ ...dashboard, themeState: { ...dashboard.themeState,
      debugPort: 54321, appliedThemeId: "skin", installed: [{id:"skin",name:"测试皮肤",version:"1",hasImage:true,installedAt:"",themeSha256:"",imageSha256:null}]
    }});
    vi.mocked(api.desktopStatus).mockResolvedValue({connected,target:"测试",conversationId:null,preset:{model:"test",reasoningEffort:"medium",serviceTier:"flex",contextWindow:272000},codexExecutable:null,debugPort:connected ? 54322 : null});
    render(<App />);
    fireEvent.click(screen.getByRole("button", {name:"主题"}));
    fireEvent.click(await screen.findByRole("button", {name:"重新应用"}));
    if (!connected) fireEvent.click(await screen.findByRole("button", {name:"确认"}));
    await waitFor(() => expect(api.applyTheme).toHaveBeenCalledWith("skin", !connected));
  });
}

test("切换对话会刷新字段，提交携带编辑时的目标与基线", async () => {
  const first = {connected:true,target:"当前对话 · first",conversationId:"first",preset:{model:"model-a",reasoningEffort:"low",serviceTier:"未提供",contextWindow:258400},codexExecutable:null,debugPort:54321};
  vi.mocked(api.desktopStatus).mockResolvedValue(first);
  render(<App />);
  fireEvent.click(screen.getByRole("button", {name:"桌面"}));
  const model = await screen.findByDisplayValue("model-a");
  fireEvent.change(model, {target:{value:"draft"}});
  fireEvent.click(within(screen.getByRole("heading", {name:"Codex Desktop 连接"}).closest("section")!).getByRole("button", {name:"刷新"}));
  await waitFor(() => expect(api.desktopStatus).toHaveBeenCalledTimes(2));
  expect(model).toHaveValue("draft");
  const second = {...first, target:"当前对话 · second",conversationId:"second",preset:{...first.preset,model:"model-b",reasoningEffort:"high"}};
  vi.mocked(api.desktopStatus).mockResolvedValue(second);
  fireEvent.click(within(screen.getByRole("heading", {name:"Codex Desktop 连接"}).closest("section")!).getByRole("button", {name:"刷新"}));
  await screen.findByDisplayValue("model-b");
  fireEvent.change(screen.getByDisplayValue("model-b"), {target:{value:"model-c"}});
  fireEvent.click(screen.getByRole("button", {name:"应用设置"}));
  await waitFor(() => expect(api.updateDesktopSettings).toHaveBeenCalledWith({...second.preset,model:"model-c"}, "second", second.preset));
});


test("分支创建期间仍能跟随对话并标注预计窗口", async () => {
  const base = {connected:true,target:"当前对话 · first",conversationId:"first",preset:{model:"gpt-6-astra",reasoningEffort:"medium",serviceTier:"default",contextWindow:245100},codexExecutable:null,debugPort:9000};
  vi.mocked(api.desktopStatus).mockResolvedValue(base);
  let release!: (id: string) => void;
  vi.mocked(api.createContextBranch).mockImplementation(() => new Promise(resolve => {release=resolve;}));
  render(<App />);
  fireEvent.click(await screen.findByRole("button", {name:"桌面"}));
  await screen.findByText("当前对话 · first");
  expect(await screen.findByRole("option", {name:"配置 1,000,000 → 预计有效 828,400（受模型上限限制）"})).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", {name:"继承历史创建分支"}));
  fireEvent.click(await screen.findByRole("button", {name:"确认"}));
  await waitFor(() => expect(api.createContextBranch).toHaveBeenCalledWith("first",1000000));
  vi.mocked(api.desktopStatus).mockResolvedValue({...base,target:"当前对话 · second",conversationId:"second"});
  fireEvent.click(within(screen.getByText("Codex Desktop 连接").closest("section")!).getByRole("button", {name:"刷新"}));
  await screen.findByText("当前对话 · second");
  release("branch");
  await screen.findByText("分支已创建，窗口配置已保存；实际容量待下一轮上报");
});
