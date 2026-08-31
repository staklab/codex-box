import { useCallback, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api } from "./api";
import appIcon from "./assets/codex-box.png";
import type { Account, Dashboard } from "./types";

const emptyDashboard: Dashboard = {
  accounts: [], profiles: [], cost: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, estimatedUsd: 0, sessionCount: 0 }, gateway: null, startAtLogin: false,
};

function usageColor(value: number) {
  if (value >= 100) return "danger";
  if (value >= 80) return "warning";
  return "healthy";
}

function formatTokens(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(value);
}

function AccountCard({ account, busy, onRefresh, onActivate, onRemove }: {
  account: Account; busy: boolean; onRefresh: () => void; onActivate: () => void; onRemove: () => void;
}) {
  return <article className={`account-card ${account.isActive ? "active" : ""}`}>
    <div className="account-head">
      <div><strong>{account.email || "OpenAI 账号"}</strong><span>{account.organizationName || account.planType.toUpperCase()}</span></div>
      {account.isActive && <em>当前</em>}
    </div>
    {account.tokenExpired ? <p className="error-inline">授权已过期，请重新登录</p> : <>
      <Usage label="5 小时" value={account.primaryUsedPercent} />
      <Usage label="每周" value={account.secondaryUsedPercent} />
    </>}
    <div className="card-actions">
      <button onClick={onRefresh} disabled={busy}>{busy ? "刷新中…" : "刷新"}</button>
      {!account.isActive && <button onClick={onActivate}>设为当前</button>}
      <button className="danger-button" onClick={onRemove}>移除</button>
    </div>
  </article>;
}

function Usage({ label, value }: { label: string; value: number }) {
  const bounded = Math.max(0, Math.min(value, 100));
  return <div className="usage"><div><span>{label}</span><b>{bounded.toFixed(0)}%</b></div>
    <div className="track"><i className={usageColor(bounded)} style={{ width: `${bounded}%` }} /></div></div>;
}

export default function App() {
  const [dashboard, setDashboard] = useState(emptyDashboard);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [profileName, setProfileName] = useState("");

  const load = useCallback(async () => {
    try { setDashboard(await api.dashboard()); setMessage(null); }
    catch (error) { setMessage(String(error)); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    const subscriptions = Promise.all([
      listen<Account>("oauth-completed", () => { setMessage("账号登录成功"); void load(); }),
      listen<string>("oauth-failed", event => setMessage(event.payload)),
    ]);
    return () => { void subscriptions.then(items => items.forEach(unlisten => unlisten())); };
  }, [load]);

  async function run(action: () => Promise<unknown>, success?: string) {
    try { setMessage(null); await action(); if (success) setMessage(success); await load(); }
    catch (error) { setMessage(String(error)); }
  }

  async function login() {
    try {
      setMessage("正在等待浏览器完成登录…");
      const flow = await api.startOAuth();
      await openUrl(flow.authUrl);
    } catch (error) { setMessage(String(error)); }
  }

  async function refresh(account: Account) {
    setBusyId(account.id);
    await run(() => api.refreshUsage(account.id));
    setBusyId(null);
  }

  async function addProfile() {
    const name = profileName.trim();
    if (!name) { setMessage("请输入运行档案名称"); return; }
    const active = dashboard.accounts.find(account => account.isActive);
    await run(() => api.createProfile(name, active?.id), "运行档案已创建");
    setProfileName("");
  }

  async function checkUpdate() {
    try {
      setMessage("正在检查更新…");
      const update = await api.checkUpdate();
      if (!update) { setMessage("当前已是最新版本"); return; }
      setMessage(`发现新版本 ${update.version}，正在打开下载页面`);
      await openUrl(update.downloadUrl);
    } catch (error) { setMessage(String(error)); }
  }

  return <main className="app-shell">
    <header><div className="brand"><img src={appIcon} alt="codex-box" /><div><h1>codex-box</h1><p>Windows 系统托盘伴侣</p></div></div>
      <button className="primary" onClick={() => void login()}>＋ 添加账号</button></header>

    {message && <div className="notice" role="status">{message}<button aria-label="关闭提示" onClick={() => setMessage(null)}>×</button></div>}

    <section><div className="section-title"><h2>OpenAI 账号</h2><span>{dashboard.accounts.length}</span></div>
      {loading ? <p className="empty">正在读取本地数据…</p> : dashboard.accounts.length === 0 ?
        <div className="empty"><b>还没有账号</b><p>通过浏览器 OAuth 登录；codex-box 不会改写共享凭据。</p></div> :
        <div className="account-list">{dashboard.accounts.map(account => <AccountCard key={account.id} account={account}
          busy={busyId === account.id} onRefresh={() => void refresh(account)}
          onActivate={() => void run(() => api.setActive(account.id))}
          onRemove={() => { if (confirm(`移除账号 ${account.email || account.id}？`)) void run(() => api.removeAccount(account.id)); }} />)}</div>}
    </section>

    <section><div className="section-title"><h2>本地用量与成本</h2></div>
      <div className="cost-grid"><div><span>会话</span><strong>{dashboard.cost.sessionCount}</strong></div>
        <div><span>输入 Token</span><strong>{formatTokens(dashboard.cost.inputTokens)}</strong></div>
        <div><span>输出 Token</span><strong>{formatTokens(dashboard.cost.outputTokens)}</strong></div>
        <div><span>估算成本</span><strong>${dashboard.cost.estimatedUsd.toFixed(2)}</strong></div></div>
    </section>

    <section><div className="section-title"><h2>隔离运行档案</h2><span>{dashboard.profiles.length}</span></div>
      <div className="profile-create"><input value={profileName} onChange={event => setProfileName(event.target.value)}
        onKeyDown={event => { if (event.key === "Enter") void addProfile(); }} placeholder="例如：工作账号" maxLength={60} />
        <button onClick={() => void addProfile()}>创建</button></div>
      <div className="profiles">{dashboard.profiles.map(profile => <div key={profile.id}><div><strong>{profile.name}</strong><small title={profile.codexHome}>{profile.codexHome}</small></div>
        <button onClick={() => void run(() => api.launchProfile(profile.id), "Codex CLI 已启动")}>启动</button>
        <button className="danger-button" onClick={() => { if (confirm(`删除运行档案“${profile.name}”及其隔离数据？`)) void run(() => api.removeProfile(profile.id)); }}>删除</button></div>)}</div>
    </section>

    <section><div className="section-title"><h2>本地 Responses 网关</h2>{dashboard.gateway && <span>运行中</span>}</div>
      {dashboard.gateway ? <div className="gateway-status"><p>网关只监听本机回环地址，档案启动时会自动注入连接参数。</p>
        <label>Base URL<input readOnly value={dashboard.gateway.baseUrl} /></label>
        <label>本地密钥<input readOnly type="password" value={dashboard.gateway.apiKey} /></label>
        <button className="danger-button" onClick={() => void run(() => api.stopGateway(), "网关已停止")}>停止网关</button></div> :
        <div className="gateway-status"><p>将当前 OAuth 账号安全代理为 OpenAI Responses 接口，不会写入共享 auth.json。</p>
          <button onClick={() => void run(() => api.startGateway(), "网关已启动")}>启动网关</button></div>}
    </section>

    <section><div className="section-title"><h2>应用设置</h2></div>
      <div className="settings-row"><div><strong>登录 Windows 后启动</strong><small>启动后驻留系统托盘</small></div>
        <input aria-label="登录 Windows 后启动" type="checkbox" checked={dashboard.startAtLogin}
          onChange={event => void run(() => api.setStartAtLogin(event.target.checked))} /></div>
      <div className="settings-row"><div><strong>软件更新</strong><small>从 GitHub Release 获取 Windows 安装包</small></div>
        <button onClick={() => void checkUpdate()}>检查更新</button></div>
    </section>

    <footer>共享凭据只读 · 敏感 Token 由 Windows Credential Manager 保护</footer>
  </main>;
}
