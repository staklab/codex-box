import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, test, vi } from "vitest";
import App from "./App";
import { api } from "./api";

vi.mock("./api", () => ({ api: { dashboard: vi.fn(), startOAuth: vi.fn(), refreshUsage: vi.fn(), setActive: vi.fn(), removeAccount: vi.fn(), createProfile: vi.fn(), launchProfile: vi.fn(), removeProfile: vi.fn(), startGateway: vi.fn(), stopGateway: vi.fn(), setStartAtLogin: vi.fn(), checkUpdate: vi.fn() } }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

const dashboard = { accounts: [{ id: "a1", email: "test@example.com", openaiAccountId: "org", planType: "plus", primaryUsedPercent: 25, secondaryUsedPercent: 70, primaryResetAt: null, secondaryResetAt: null, lastChecked: null, isActive: true, isSuspended: false, tokenExpired: false, organizationName: null }], profiles: [], cost: { inputTokens: 1200, cachedInputTokens: 100, outputTokens: 50, estimatedUsd: .02, sessionCount: 2 }, gateway: null, startAtLogin: false };

beforeEach(() => { vi.clearAllMocks(); vi.mocked(api.dashboard).mockResolvedValue(dashboard); });

test("renders account usage and local cost", async () => {
  render(<App />);
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
