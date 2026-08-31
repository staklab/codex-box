import { useCallback, useEffect, useMemo, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api } from "./api";
import appIcon from "./assets/codex-box.png";
import type { Account, Dashboard, DesktopStatus, RecordsSnapshot, ThemeListing, ThemePage, ThreadPreset } from "./types";

type Tab = "overview" | "desktop" | "themes" | "providers" | "records";

const emptyDashboard: Dashboard = {
  accounts: [], profiles: [], providers: [], activeProviderId: null,
  cost: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, estimatedUsd: 0, sessionCount: 0 },
  gateway: null, startAtLogin: false, autoRouteEnabled: false, autoRouteThreshold: 90,
  themeState: { installed: [], appliedThemeId: null, autoReapply: false, codexExecutable: null, debugPort: null },
  themeSources: [],
};

function usageColor(value: number) { return value >= 100 ? "danger" : value >= 80 ? "warning" : "healthy"; }
function formatTokens(value: number) { return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(1)}M` : value >= 1_000 ? `${(value / 1_000).toFixed(1)}K` : String(value); }
function formatTime(value: string | null) { return value ? new Date(value).toLocaleString("zh-CN") : "—"; }

function Usage({ label, value }: { label: string; value: number }) {
  const bounded = Math.max(0, Math.min(value, 100));
  return <div className="usage"><div><span>{label}</span><b>{bounded.toFixed(0)}%</b></div><div className="track"><i className={usageColor(bounded)} style={{ width: `${bounded}%` }} /></div></div>;
}

function AccountCard({ account, busy, onRefresh, onActivate, onRemove }: { account: Account; busy: boolean; onRefresh: () => void; onActivate: () => void; onRemove: () => void }) {
  return <article className={`account-card ${account.isActive ? "active" : ""}`}>
    <div className="account-head"><div><strong>{account.email || "OpenAI 账号"}</strong><span>{account.organizationName || account.planType.toUpperCase()}</span></div>{account.isActive && <em>当前</em>}</div>
    {account.tokenExpired ? <p className="error-inline">授权已过期，请重新登录</p> : <><Usage label="5 小时" value={account.primaryUsedPercent} /><Usage label="每周" value={account.secondaryUsedPercent} /></>}
    <div className="card-actions"><button onClick={onRefresh} disabled={busy}>{busy ? "刷新中…" : "刷新"}</button>{!account.isActive && <button onClick={onActivate}>设为当前</button>}<button className="danger-button" onClick={onRemove}>移除</button></div>
  </article>;
}

function Overview({ dashboard, loading, busyId, setBusyId, run, login, manualFlowId }: {
  dashboard: Dashboard; loading: boolean; busyId: string | null; setBusyId: (value: string | null) => void;
  run: (action: () => Promise<unknown>, success?: string) => Promise<void>; login: () => Promise<void>; manualFlowId: string | null;
}) {
  const [profileName, setProfileName] = useState("");
  const [transferPath, setTransferPath] = useState("");
  const [manualCallback, setManualCallback] = useState("");
  async function addProfile() {
    const name = profileName.trim();
    if (!name) return;
    const active = dashboard.accounts.find(account => account.isActive);
    await run(() => api.createProfile(name, active?.id), "运行档案已创建");
    setProfileName("");
  }
  return <>
    <section><div className="section-title"><h2>OpenAI 账号</h2><span>{dashboard.accounts.length}</span><button className="section-action" onClick={() => void login()}>＋ 添加</button></div>
      {loading ? <p className="empty">正在读取本地数据…</p> : dashboard.accounts.length === 0 ? <div className="empty"><b>还没有账号</b><p>通过浏览器 OAuth 登录；共享凭据保持只读。</p></div> :
        <div className="account-list">{dashboard.accounts.map(account => <AccountCard key={account.id} account={account} busy={busyId === account.id}
          onRefresh={() => { setBusyId(account.id); void run(() => api.refreshUsage(account.id)).finally(() => setBusyId(null)); }}
          onActivate={() => void run(() => api.setActive(account.id))}
          onRemove={() => { if (confirm(`移除账号 ${account.email || account.id}？`)) void run(() => api.removeAccount(account.id)); }} />)}</div>}
    </section>
    <section><div className="section-title"><h2>高级账号管理</h2></div><p className="section-hint">兼容 rhino2api JSON 和旧版 CSV。导出文件包含敏感凭据，请只保存到可信位置。</p>
      <div className="inline-form"><input value={transferPath} onChange={event => setTransferPath(event.target.value)} placeholder="账号 JSON/CSV 的绝对路径" /><button disabled={!transferPath.trim()} onClick={() => void run(() => api.importAccounts(transferPath.trim()), "账号已安全导入")}>导入</button><button disabled={!transferPath.trim().toLowerCase().endsWith(".json")} onClick={() => void run(() => api.exportAccounts(transferPath.trim()), "账号已导出")}>导出</button></div>
      {manualFlowId && <div className="manual-callback"><label>自动回调失败时，粘贴完整 localhost 回调 URL 或授权 code</label><div className="inline-form"><input value={manualCallback} onChange={event => setManualCallback(event.target.value)} /><button disabled={!manualCallback.trim()} onClick={() => void run(() => api.completeOAuth(manualFlowId, manualCallback.trim()), "账号登录成功")}>完成登录</button></div></div>}
    </section>
    <section><div className="section-title"><h2>本地用量与成本</h2></div><div className="cost-grid">
      <div><span>会话</span><strong>{dashboard.cost.sessionCount}</strong></div><div><span>输入 Token</span><strong>{formatTokens(dashboard.cost.inputTokens)}</strong></div>
      <div><span>输出 Token</span><strong>{formatTokens(dashboard.cost.outputTokens)}</strong></div><div><span>估算成本</span><strong>${dashboard.cost.estimatedUsd.toFixed(2)}</strong></div>
    </div></section>
    <section><div className="section-title"><h2>隔离运行档案</h2><span>{dashboard.profiles.length}</span></div>
      <div className="inline-form"><input value={profileName} onChange={event => setProfileName(event.target.value)} onKeyDown={event => { if (event.key === "Enter") void addProfile(); }} placeholder="例如：工作账号" maxLength={60} /><button onClick={() => void addProfile()}>创建</button></div>
      <div className="profiles">{dashboard.profiles.map(profile => <div key={profile.id}><div><strong>{profile.name}</strong><small title={profile.codexHome}>{profile.codexHome}</small></div><button onClick={() => void run(() => api.launchProfile(profile.id), "Codex CLI 已启动")}>启动</button><button className="danger-button" onClick={() => { if (confirm(`删除运行档案“${profile.name}”及其隔离数据？`)) void run(() => api.removeProfile(profile.id)); }}>删除</button></div>)}</div>
    </section>
    <section><div className="section-title"><h2>本地 Responses 网关</h2>{dashboard.gateway && <span>运行中</span>}</div>
      {dashboard.gateway ? <div className="gateway-status"><p>当前路由：{dashboard.gateway.accountEmail}</p><label>Base URL<input readOnly value={dashboard.gateway.baseUrl} /></label><label>本地密钥<input readOnly type="password" value={dashboard.gateway.apiKey} /></label><button className="danger-button" onClick={() => void run(() => api.stopGateway(), "网关已停止")}>停止网关</button></div> : <div className="gateway-status"><p>为当前 OAuth 账号或 Provider 建立仅监听回环地址的网关。</p><button onClick={() => void run(() => api.startGateway(), "网关已启动")}>启动网关</button></div>}
    </section>
    <section><div className="section-title"><h2>应用设置</h2></div><div className="settings-row"><div><strong>登录 Windows 后启动</strong><small>启动后驻留系统托盘</small></div><input aria-label="登录 Windows 后启动" type="checkbox" checked={dashboard.startAtLogin} onChange={event => void run(() => api.setStartAtLogin(event.target.checked))} /></div>
      <div className="settings-row"><div><strong>用量自动路由</strong><small>达到阈值时切换到可用量更多的 OAuth 账号</small></div><input aria-label="用量自动路由" type="checkbox" checked={dashboard.autoRouteEnabled} onChange={event => void run(() => api.setAutoRoute(event.target.checked, dashboard.autoRouteThreshold), "自动路由设置已保存")} /></div>
      <div className="settings-row"><div><strong>切换阈值</strong><small>{dashboard.autoRouteThreshold.toFixed(0)}%</small></div><input aria-label="自动路由阈值" className="range" type="range" min="50" max="100" value={dashboard.autoRouteThreshold} onChange={event => void run(() => api.setAutoRoute(dashboard.autoRouteEnabled, Number(event.target.value)))} /></div>
      <div className="settings-row"><div><strong>软件更新</strong><small>从 GitHub Release 获取 Windows 安装包</small></div><button onClick={() => void run(async () => { const update = await api.checkUpdate(); if (update) await openUrl(update.downloadUrl); }, "更新检查完成")}>检查更新</button></div></section>
  </>;
}

function DesktopPanel({ dashboard, run }: { dashboard: Dashboard; run: (action: () => Promise<unknown>, success?: string) => Promise<void> }) {
  const [status, setStatus] = useState<DesktopStatus | null>(null);
  const [path, setPath] = useState(dashboard.themeState.codexExecutable || "");
  const [preset, setPreset] = useState<ThreadPreset>({ model: "gpt-5.6-sol", reasoningEffort: "medium", serviceTier: "flex", contextWindow: 272000 });
  const refresh = useCallback(async () => { const next = await api.desktopStatus(); setStatus(next); setPreset(next.preset); setPath(next.codexExecutable || ""); }, []);
  useEffect(() => { void refresh(); }, [refresh]);
  function field<K extends keyof ThreadPreset>(key: K, value: ThreadPreset[K]) { setPreset(current => ({ ...current, [key]: value })); }
  return <>
    <section><div className="section-title"><h2>Codex Desktop 连接</h2><span className={status?.connected ? "ok-pill" : ""}>{status?.connected ? "已连接" : "未连接"}</span><button className="section-action" onClick={() => void refresh()}>刷新</button></div>
      <p className="section-hint">进程和 CDP 探测只在此页按需执行，不参与窗口打开和滚动渲染。</p>
      <div className="field"><label>Codex.exe 路径</label><div className="inline-form"><input value={path} onChange={event => setPath(event.target.value)} placeholder="C:\…\Codex.exe" /><button onClick={() => void run(() => api.setCodexExecutable(path), "程序路径已保存")}>保存</button></div></div>
      <div className="status-grid"><div><span>设置目标</span><strong>{status?.target || "读取中…"}</strong></div><div><span>CDP 端口</span><strong>{status?.debugPort || "—"}</strong></div></div>
      <div className="settings-row"><div><strong>自动恢复主题</strong><small>启动 codex-box 后恢复已应用主题</small></div><input aria-label="自动恢复主题" type="checkbox" checked={dashboard.themeState.autoReapply} onChange={event => void run(() => api.setAutoReapply(event.target.checked), "主题恢复设置已保存")} /></div>
    </section>
    <section><div className="section-title"><h2>对话运行参数</h2></div><p className="section-hint">已连接时写入当前对话；首页状态下写入新对话默认值。</p>
      <div className="form-grid"><label>模型<input value={preset.model} onChange={event => field("model", event.target.value)} /></label><label>推理强度<select value={preset.reasoningEffort} onChange={event => field("reasoningEffort", event.target.value)}>{["none","minimal","low","medium","high","xhigh","max","ultra"].map(value => <option key={value}>{value}</option>)}</select></label><label>Service tier<select value={preset.serviceTier} onChange={event => field("serviceTier", event.target.value)}>{["auto","default","flex","priority"].map(value => <option key={value}>{value}</option>)}</select></label><label>上下文窗口<input type="number" min={16000} max={2000000} value={preset.contextWindow} onChange={event => field("contextWindow", Number(event.target.value))} /></label></div>
      <button className="primary wide" onClick={() => void run(() => api.updateDesktopSettings(preset), "对话设置已更新")}>应用设置</button>
    </section>
  </>;
}

function ThemeCard({ item, installed, applied, busy, onInstall, onApply, onRemove }: { item: ThemeListing; installed: boolean; applied: boolean; busy: boolean; onInstall: () => void; onApply: () => void; onRemove: () => void }) {
  const colors = item.inlineColors ? Object.values(item.inlineColors).filter(Boolean).slice(0, 5) : [];
  return <article className={`theme-card ${applied ? "applied" : ""}`}><div className="theme-head"><div><strong>{item.name}</strong><small>{item.author || item.sourceName} · {item.version}</small></div>{applied && <em>已应用</em>}</div>{colors.length > 0 && <div className="swatches">{colors.map((color, index) => <i key={`${color}-${index}`} style={{ background: color }} />)}</div>}<p>{item.description || item.tags.join(" · ") || "主题配色与壁纸"}</p><div className="card-actions">{installed ? <><button disabled={busy || applied} onClick={onApply}>{applied ? "使用中" : "应用"}</button><button className="danger-button" disabled={busy || applied} onClick={onRemove}>卸载</button></> : <button disabled={busy} onClick={onInstall}>{busy ? "处理中…" : "安装"}</button>}</div></article>;
}

function ThemesPanel({ dashboard, reload, showMessage }: { dashboard: Dashboard; reload: () => Promise<void>; showMessage: (value: string) => void }) {
  const [page, setPage] = useState<ThemePage>({ items: [], total: 0, offset: 0, limit: 24, issues: [] });
  const [query, setQuery] = useState(""); const [busy, setBusy] = useState<string | null>(null); const [dreamId, setDreamId] = useState(""); const [localPath, setLocalPath] = useState(""); const [sourceName, setSourceName] = useState(""); const [sourceUrl, setSourceUrl] = useState(""); const [loaded, setLoaded] = useState(false);
  const installed = useMemo(() => new Set(dashboard.themeState.installed.map(item => item.id)), [dashboard.themeState.installed]);
  async function action(id: string, work: () => Promise<unknown>, message: string) { try { setBusy(id); await work(); await reload(); showMessage(message); } catch (error) { showMessage(String(error)); } finally { setBusy(null); } }
  async function refresh() { try { setBusy("market"); const next = await api.refreshThemes(query); setPage(next); setLoaded(true); } catch (error) { showMessage(String(error)); } finally { setBusy(null); } }
  async function move(offset: number) { try { setPage(await api.themePage(offset, page.limit, query)); } catch (error) { showMessage(String(error)); } }
  const installedListings: ThemeListing[] = dashboard.themeState.installed.map(item => ({ id: item.id, name: item.name, version: item.version, author: null, description: item.hasImage ? "包含壁纸" : "配色主题", license: null, tags: [], theme: "", preview: null, sourceBaseUrl: "installed://", sourceName: "已安装", isPack: false, declaredSha256: null, inlineColors: null, inlineAppearance: null }));
  return <>
    <section><div className="section-title"><h2>已安装主题</h2><span>{installedListings.length}</span>{dashboard.themeState.appliedThemeId && <button className="section-action danger-button" onClick={() => void action("revert", api.revertTheme, "已恢复默认主题")}>恢复默认</button>}</div>
      {installedListings.length === 0 ? <p className="empty">还没有安装主题</p> : <div className="theme-grid">{installedListings.map(item => <ThemeCard key={item.id} item={item} installed applied={dashboard.themeState.appliedThemeId === item.id} busy={busy === item.id} onInstall={() => {}} onApply={() => { const restart = !dashboard.themeState.debugPort && confirm("首次应用需要以安全的随机 CDP 端口启动 Codex，继续吗？"); if (dashboard.themeState.debugPort || restart) void action(item.id, () => api.applyTheme(item.id, restart), "主题已应用"); }} onRemove={() => { if (confirm(`卸载主题“${item.name}”？`)) void action(item.id, () => api.uninstallTheme(item.id), "主题已卸载"); }} />)}</div>}
    </section>
    <section><div className="section-title"><h2>DreamSkin 与本地主题</h2></div><div className="stacked-forms"><div className="inline-form"><input value={dreamId} onChange={event => setDreamId(event.target.value)} placeholder="DreamSkin 版本 ID：ver_…" /><button disabled={!dreamId.trim() || busy !== null} onClick={() => void action("dream", () => api.installDreamSkin(dreamId.trim()), "DreamSkin 主题已安装")}>安装</button></div><div className="inline-form"><input value={localPath} onChange={event => setLocalPath(event.target.value)} placeholder="本地主题目录（包含 theme.json）" /><button disabled={!localPath.trim() || busy !== null} onClick={() => void action("local", () => api.importLocalTheme(localPath.trim()), "本地主题已导入")}>导入</button></div><button onClick={() => void openUrl("https://dreamskin.cc/gallery")}>打开 DreamSkin 画廊</button></div></section>
    <section><div className="section-title"><h2>主题市场</h2>{loaded && <span>{page.total}</span>}<button className="section-action" disabled={busy === "market"} onClick={() => void refresh()}>{busy === "market" ? "加载中…" : "刷新市场"}</button></div>
      <div className="source-list">{dashboard.themeSources.map(source => <label key={source.id}><input type="checkbox" checked={source.enabled} onChange={event => void action(`source-${source.id}`, () => api.setThemeSource(source.id, event.target.checked), "主题源设置已保存")} /><span>{source.name}</span></label>)}</div>
      <div className="custom-source"><input value={sourceName} onChange={event => setSourceName(event.target.value)} placeholder="自定义源名称" /><input value={sourceUrl} onChange={event => setSourceUrl(event.target.value)} placeholder="https://…（包含 index.json）" /><button disabled={!sourceName.trim() || !sourceUrl.trim()} onClick={() => void action("source-add", () => api.addThemeSource(sourceName.trim(), sourceUrl.trim()), "主题源已添加")}>添加源</button></div>
      <div className="inline-form search-row"><input value={query} onChange={event => setQuery(event.target.value)} onKeyDown={event => { if (event.key === "Enter") void refresh(); }} placeholder="搜索名称、作者或标签" /><button onClick={() => void refresh()}>搜索</button></div>
      {page.issues.length > 0 && <div className="warning-box">{page.issues.map(issue => <p key={issue}>{issue}</p>)}</div>}
      {!loaded ? <p className="empty">按需刷新市场；列表每页最多渲染 24 个主题。</p> : <div className="theme-grid">{page.items.map(item => <ThemeCard key={`${item.sourceName}-${item.id}`} item={item} installed={installed.has(item.id)} applied={dashboard.themeState.appliedThemeId === item.id} busy={busy === item.id} onInstall={() => void action(item.id, () => api.installTheme(item.id, item.sourceName), "主题已安装")} onApply={() => void action(item.id, () => api.applyTheme(item.id, true), "主题已应用")} onRemove={() => void action(item.id, () => api.uninstallTheme(item.id), "主题已卸载")} />)}</div>}
      {loaded && page.total > page.limit && <div className="pager"><button disabled={page.offset === 0} onClick={() => void move(Math.max(0, page.offset - page.limit))}>上一页</button><span>{Math.floor(page.offset / page.limit) + 1} / {Math.ceil(page.total / page.limit)}</span><button disabled={page.offset + page.limit >= page.total} onClick={() => void move(page.offset + page.limit)}>下一页</button></div>}
    </section>
  </>;
}

function ProvidersPanel({ dashboard, run }: { dashboard: Dashboard; run: (action: () => Promise<unknown>, success?: string) => Promise<void> }) {
  const [form, setForm] = useState({ label: "", kind: "openAiCompatible", baseUrl: "https://api.openai.com/v1", model: "", accountLabel: "默认", apiKey: "" });
  const [accountProviderId, setAccountProviderId] = useState(""); const [accountLabel, setAccountLabel] = useState(""); const [accountKey, setAccountKey] = useState("");
  function set(key: keyof typeof form, value: string) { setForm(current => ({ ...current, [key]: value })); }
  async function create() { await run(() => api.createProvider(form), "Provider 已保存"); setForm(current => ({ ...current, apiKey: "" })); }
  return <><section><div className="section-title"><h2>请求路由</h2></div><p className="section-hint">密钥存入 Windows Credential Manager；公开配置只保存 Provider 元数据。</p>
    <div className="provider-list"><label className={dashboard.activeProviderId === null ? "active" : ""}><input type="radio" checked={dashboard.activeProviderId === null} onChange={() => void run(() => api.setActiveProvider(null), "已选择 OpenAI OAuth 路由")} /><div><strong>OpenAI OAuth</strong><small>使用当前 OAuth 账号</small></div></label>{dashboard.providers.map(provider => <div className={`provider-block ${dashboard.activeProviderId === provider.id ? "active" : ""}`} key={provider.id}><div className="provider-route"><input aria-label={`激活 ${provider.label}`} type="radio" checked={dashboard.activeProviderId === provider.id} onChange={() => void run(() => api.setActiveProvider(provider.id), "Provider 已激活")} /><div><strong>{provider.label}</strong><small>{provider.model} · {provider.baseUrl}</small></div><button className="danger-button" onClick={() => { if (confirm(`删除 Provider“${provider.label}”？`)) void run(() => api.removeProvider(provider.id)); }}>删除</button></div><div className="provider-accounts">{provider.accounts.map(account => <label key={account.id}><input type="radio" checked={provider.activeAccountId === account.id} onChange={() => void run(() => api.setActiveProviderAccount(provider.id, account.id), "Provider 账号已切换")} /><span>{account.label}</span><button className="danger-button" onClick={event => { event.preventDefault(); if (confirm(`删除账号“${account.label}”？`)) void run(() => api.removeProviderAccount(provider.id, account.id)); }}>移除</button></label>)}</div></div>)}</div>
    {dashboard.providers.length > 0 && <div className="provider-account-form"><select value={accountProviderId} onChange={event => setAccountProviderId(event.target.value)}><option value="">选择 Provider</option>{dashboard.providers.map(provider => <option key={provider.id} value={provider.id}>{provider.label}</option>)}</select><input value={accountLabel} onChange={event => setAccountLabel(event.target.value)} placeholder="账号名称" /><input type="password" value={accountKey} onChange={event => setAccountKey(event.target.value)} placeholder="API Key" /><button disabled={!accountProviderId || !accountLabel.trim() || !accountKey.trim()} onClick={() => void run(() => api.addProviderAccount(accountProviderId, accountLabel.trim(), accountKey.trim()), "Provider 账号已添加").then(() => { setAccountLabel(""); setAccountKey(""); })}>添加账号</button></div>}
  </section><section><div className="section-title"><h2>添加 Provider</h2></div><div className="form-grid"><label>名称<input value={form.label} onChange={event => set("label", event.target.value)} /></label><label>类型<select value={form.kind} onChange={event => set("kind", event.target.value)}><option value="openAiCompatible">OpenAI Compatible</option><option value="openRouter">OpenRouter</option></select></label><label className="span-2">Base URL<input value={form.baseUrl} onChange={event => set("baseUrl", event.target.value)} /></label><label>模型 ID<input value={form.model} onChange={event => set("model", event.target.value)} /></label><label>账号名称<input value={form.accountLabel} onChange={event => set("accountLabel", event.target.value)} /></label><label className="span-2">API Key<input type="password" value={form.apiKey} onChange={event => set("apiKey", event.target.value)} /></label></div><button className="primary wide" onClick={() => void create()}>安全保存</button></section></>;
}

function RecordsPanel({ showMessage }: { showMessage: (message: string) => void }) {
  const [snapshot, setSnapshot] = useState<RecordsSnapshot | null>(null); const [offset, setOffset] = useState(0); const pageSize = 50;
  const load = useCallback(async () => { try { setSnapshot(await api.records()); setOffset(0); } catch (error) { showMessage(String(error)); } }, [showMessage]);
  useEffect(() => { void load(); }, [load]);
  return <><section><div className="section-title"><h2>历史记录</h2><span>{snapshot?.sessions.length || 0}</span><button className="section-action" onClick={() => void load()}>重建</button></div><p className="section-hint">最多扫描最近 2,000 个会话文件；解析在后台线程执行。</p>
    <div className="model-list">{snapshot?.models.map(model => <div key={model.modelId}><strong>{model.modelId}</strong><span>{model.sessionCount} 个会话</span><small>{formatTime(model.lastSeenAt)}</small></div>)}</div></section>
    <section><div className="section-title"><h2>会话</h2></div><div className="record-table">{snapshot?.sessions.slice(offset, offset + pageSize).map(session => <div key={`${session.fileName}-${session.sessionId}`}><div><strong>{session.sessionId.slice(0, 12)}</strong><small>{session.modelId}</small></div><span>{formatTokens(session.totalTokens)}</span><time>{formatTime(session.lastActivityAt)}</time></div>)}</div>{snapshot && snapshot.sessions.length > pageSize && <div className="pager"><button disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - pageSize))}>上一页</button><span>{Math.floor(offset / pageSize) + 1} / {Math.ceil(snapshot.sessions.length / pageSize)}</span><button disabled={offset + pageSize >= snapshot.sessions.length} onClick={() => setOffset(offset + pageSize)}>下一页</button></div>}</section>
    {snapshot && snapshot.warnings.length > 0 && <section><div className="section-title"><h2>解析告警</h2><span>{snapshot.warnings.length}</span></div><div className="warning-box">{snapshot.warnings.map(warning => <p key={warning}>{warning}</p>)}</div></section>}
  </>;
}

export default function App() {
  const [dashboard, setDashboard] = useState(emptyDashboard); const [loading, setLoading] = useState(true); const [busyId, setBusyId] = useState<string | null>(null); const [message, setMessage] = useState<string | null>(null); const [tab, setTab] = useState<Tab>("overview"); const [manualFlowId, setManualFlowId] = useState<string | null>(null);
  const load = useCallback(async () => { try { setDashboard(await api.dashboard()); } catch (error) { setMessage(String(error)); } finally { setLoading(false); } }, []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { const subscriptions = Promise.all([listen<Account>("oauth-completed", () => { setMessage("账号登录成功"); void load(); }), listen<string>("oauth-failed", event => setMessage(event.payload)), listen<string>("theme-applied", event => { setMessage(event.payload); void load(); }), listen("dashboard-changed", () => void load())]); return () => { void subscriptions.then(items => items.forEach(unlisten => unlisten())); }; }, [load]);
  async function run(action: () => Promise<unknown>, success?: string) { try { setMessage(null); await action(); if (success) setMessage(success); await load(); } catch (error) { setMessage(String(error)); } }
  async function login() { try { setMessage("正在等待浏览器完成登录…"); const flow = await api.startOAuth(); setManualFlowId(flow.flowId); await openUrl(flow.authUrl); } catch (error) { setMessage(String(error)); } }
  const labels: Array<[Tab, string]> = [["overview", "概览"], ["desktop", "桌面"], ["themes", "主题"], ["providers", "路由"], ["records", "记录"]];
  return <main className="app-frame"><header><div className="brand"><img src={appIcon} alt="codex-box" /><div><h1>codex-box</h1><p>Windows 系统托盘伴侣</p></div></div><span className="safety-badge">共享凭据只读</span></header>
    <nav aria-label="功能导航">{labels.map(([id, label]) => <button key={id} className={tab === id ? "active" : ""} onClick={() => setTab(id)}>{label}</button>)}</nav>
    {message && <div className="notice" role="status">{message}<button aria-label="关闭提示" onClick={() => setMessage(null)}>×</button></div>}
    <div className="content-scroll">{tab === "overview" && <Overview dashboard={dashboard} loading={loading} busyId={busyId} setBusyId={setBusyId} run={run} login={login} manualFlowId={manualFlowId} />}{tab === "desktop" && <DesktopPanel dashboard={dashboard} run={run} />}{tab === "themes" && <ThemesPanel dashboard={dashboard} reload={load} showMessage={setMessage} />}{tab === "providers" && <ProvidersPanel dashboard={dashboard} run={run} />}{tab === "records" && <RecordsPanel showMessage={setMessage} />}</div>
    <footer>敏感凭据由 Windows Credential Manager 保护</footer>
  </main>;
}
