mod account_transfer;
mod config_edit;
mod cost;
mod desktop;
mod gateway;
mod models;
mod oauth;
mod paths;
mod profiles;
mod records;
mod store;
mod themes;
mod update;
mod usage;

use models::{
    Account, CostSummary, DesktopStatus, GatewayStatus, Profile, Provider, RecordsSnapshot,
    ThemeListing, ThemePage, ThemeSource, ThemeState, ThreadPreset,
};
use oauth::{OAuthService, StartedFlow};
use serde::Serialize;
use std::sync::{Arc, Mutex};
use store::Store;
use tauri::{Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct AppContext {
    store: Mutex<Store>,
    oauth: OAuthService,
    gateway: Mutex<Option<gateway::GatewayRuntime>>,
    theme_catalog: Mutex<Vec<ThemeListing>>,
    theme_issues: Mutex<Vec<String>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Dashboard {
    accounts: Vec<Account>,
    profiles: Vec<Profile>,
    cost: CostSummary,
    gateway: Option<GatewayStatus>,
    start_at_login: bool,
    providers: Vec<Provider>,
    active_provider_id: Option<String>,
    theme_state: ThemeState,
    theme_sources: Vec<ThemeSource>,
    auto_route_enabled: bool,
    auto_route_threshold: f64,
}

fn error_message(error: impl std::fmt::Display) -> String {
    error.to_string()
}

#[tauri::command]
async fn get_dashboard(
    app: tauri::AppHandle,
    context: tauri::State<'_, Arc<AppContext>>,
) -> Result<Dashboard, String> {
    use tauri_plugin_autostart::ManagerExt;
    let (
        accounts,
        profiles,
        start_at_login,
        providers,
        active_provider_id,
        theme_state,
        theme_sources,
        auto_route_enabled,
        auto_route_threshold,
    ) = {
        let store = context.store.lock().map_err(error_message)?;
        (
            store.accounts(),
            store.config().profiles.clone(),
            store.config().start_at_login,
            store.config().providers.clone(),
            store.config().active_provider_id.clone(),
            store.theme_state(),
            store.config().theme_sources.clone(),
            store.config().auto_route_enabled,
            store.config().auto_route_threshold,
        )
    };
    let sessions = paths::codex_root().map_err(error_message)?.join("sessions");
    let cost = tokio::task::spawn_blocking(move || cost::summarize(&sessions))
        .await
        .map_err(error_message)?
        .map_err(error_message)?;
    let gateway = context
        .gateway
        .lock()
        .map_err(error_message)?
        .as_ref()
        .map(|runtime| runtime.status.clone());
    let start_at_login = app.autolaunch().is_enabled().unwrap_or(start_at_login);
    Ok(Dashboard {
        accounts,
        profiles,
        cost,
        gateway,
        start_at_login,
        providers,
        active_provider_id,
        theme_state,
        theme_sources,
        auto_route_enabled,
        auto_route_threshold,
    })
}

#[tauri::command]
async fn start_oauth(
    app: tauri::AppHandle,
    context: tauri::State<'_, Arc<AppContext>>,
) -> Result<StartedFlow, String> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:1455")
        .await
        .map_err(|error| format!("无法启动 OAuth 回调监听器（端口 1455）：{error}"))?;
    let started = context.oauth.start().map_err(error_message)?;
    let flow_id = started.flow_id.clone();
    let owned_context = context.inner().clone();
    tauri::async_runtime::spawn(async move {
        let result = receive_callback(listener)
            .await
            .map(|callback| (callback, owned_context.clone()));
        match result {
            Ok((callback, context)) => {
                match complete_oauth_internal(&context, &flow_id, &callback).await {
                    Ok(account) => {
                        let _ = app.emit("oauth-completed", &account);
                    }
                    Err(error) => {
                        let _ = app.emit("oauth-failed", error);
                    }
                }
            }
            Err(error) => {
                let _ = app.emit("oauth-failed", error.to_string());
            }
        }
    });
    Ok(started)
}

#[tauri::command]
async fn complete_oauth(
    context: tauri::State<'_, Arc<AppContext>>,
    flow_id: String,
    callback: String,
) -> Result<Account, String> {
    complete_oauth_internal(context.inner(), &flow_id, &callback).await
}

async fn complete_oauth_internal(
    context: &Arc<AppContext>,
    flow_id: &str,
    callback: &str,
) -> Result<Account, String> {
    let (account, credentials) = context
        .oauth
        .complete(flow_id, callback)
        .await
        .map_err(error_message)?;
    context
        .store
        .lock()
        .map_err(error_message)?
        .upsert_account(account.clone(), Some(&credentials))
        .map_err(error_message)?;
    Ok(account)
}

async fn receive_callback(listener: tokio::net::TcpListener) -> anyhow::Result<String> {
    let (mut stream, _) =
        tokio::time::timeout(std::time::Duration::from_secs(300), listener.accept()).await??;
    let mut buffer = vec![0_u8; 8192];
    let count =
        tokio::time::timeout(std::time::Duration::from_secs(5), stream.read(&mut buffer)).await??;
    let request = String::from_utf8_lossy(&buffer[..count]);
    let target = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .ok_or_else(|| anyhow::anyhow!("OAuth 回调请求格式无效"))?;
    if !target.starts_with("/auth/callback?") {
        anyhow::bail!("OAuth 回调路径无效");
    }
    let callback = format!("http://localhost:1455{target}");
    let body = "<!doctype html><meta charset='utf-8'><title>codex-box</title><style>body{font:16px system-ui;background:#101215;color:#f4f4f5;display:grid;place-items:center;height:100vh;margin:0}main{text-align:center}</style><main><h1>登录已完成</h1><p>可以关闭此页面并返回 codex-box。</p></main>";
    let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
    stream.write_all(response.as_bytes()).await?;
    Ok(callback)
}

#[tauri::command]
async fn refresh_usage(
    context: tauri::State<'_, Arc<AppContext>>,
    account_id: String,
) -> Result<Account, String> {
    let (mut account, credentials) = {
        let store = context.store.lock().map_err(error_message)?;
        (
            store.account(&account_id).map_err(error_message)?,
            store.credentials(&account_id).map_err(error_message)?,
        )
    };
    match usage::fetch(&account, &credentials).await {
        Ok(snapshot) => {
            account.plan_type = snapshot.plan_type;
            account.primary_used_percent = snapshot.primary_used_percent;
            account.secondary_used_percent = snapshot.secondary_used_percent;
            account.primary_reset_at = snapshot.primary_reset_at;
            account.secondary_reset_at = snapshot.secondary_reset_at;
            account.last_checked = Some(chrono::Utc::now());
            account.token_expired = false;
        }
        Err(error) if error.to_string() == "TOKEN_EXPIRED" => {
            account.token_expired = true;
            context
                .store
                .lock()
                .map_err(error_message)?
                .upsert_account(account, None)
                .map_err(error_message)?;
            return Err(
                "登录已过期，请重新授权；codex-box 不会在后台轮换共享 refresh token".into(),
            );
        }
        Err(error) => return Err(error_message(error)),
    }
    context
        .store
        .lock()
        .map_err(error_message)?
        .upsert_account(account.clone(), None)
        .map_err(error_message)?;
    let _ = context
        .store
        .lock()
        .map_err(error_message)?
        .auto_route_if_needed()
        .map_err(error_message)?;
    Ok(account)
}

#[tauri::command]
fn set_active_account(
    context: tauri::State<'_, Arc<AppContext>>,
    account_id: String,
) -> Result<(), String> {
    context.gateway.lock().map_err(error_message)?.take();
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_active(&account_id)
        .map_err(error_message)
}

#[tauri::command]
fn remove_account(
    context: tauri::State<'_, Arc<AppContext>>,
    account_id: String,
) -> Result<(), String> {
    let gateway_uses_account = context
        .gateway
        .lock()
        .map_err(error_message)?
        .as_ref()
        .is_some_and(|runtime| runtime.status.account_id == account_id);
    if gateway_uses_account {
        context.gateway.lock().map_err(error_message)?.take();
    }
    context
        .store
        .lock()
        .map_err(error_message)?
        .remove_account(&account_id)
        .map_err(error_message)
}

#[tauri::command]
fn export_accounts(
    context: tauri::State<'_, Arc<AppContext>>,
    path: String,
) -> Result<usize, String> {
    let store = context.store.lock().map_err(error_message)?;
    let accounts = store
        .accounts()
        .into_iter()
        .map(|account| {
            let credentials = store.credentials(&account.id).map_err(error_message)?;
            Ok::<_, String>((account, credentials))
        })
        .collect::<Result<Vec<_>, _>>()?;
    account_transfer::export_json(std::path::Path::new(path.trim()), accounts)
        .map_err(error_message)
}

#[tauri::command]
fn import_accounts(
    context: tauri::State<'_, Arc<AppContext>>,
    path: String,
) -> Result<usize, String> {
    let (accounts, active) =
        account_transfer::import(std::path::Path::new(path.trim())).map_err(error_message)?;
    let count = accounts.len();
    let mut store = context.store.lock().map_err(error_message)?;
    for (mut account, credentials) in accounts {
        account.is_active = false;
        store
            .upsert_account(account, Some(&credentials))
            .map_err(error_message)?;
    }
    if let Some(active) = active {
        store.set_active(&active).map_err(error_message)?;
    }
    Ok(count)
}

#[tauri::command]
fn create_profile(
    context: tauri::State<'_, Arc<AppContext>>,
    name: String,
    account_id: Option<String>,
) -> Result<Profile, String> {
    let profile = profiles::create(name, account_id).map_err(error_message)?;
    context
        .store
        .lock()
        .map_err(error_message)?
        .add_profile(profile.clone())
        .map_err(error_message)?;
    Ok(profile)
}

#[tauri::command]
async fn launch_profile(
    context: tauri::State<'_, Arc<AppContext>>,
    profile_id: String,
) -> Result<(), String> {
    let profile = context
        .store
        .lock()
        .map_err(error_message)?
        .config()
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .cloned()
        .ok_or_else(|| "运行档案不存在".to_owned())?;
    let mut gateway = context
        .gateway
        .lock()
        .map_err(error_message)?
        .as_ref()
        .map(|runtime| runtime.status.clone());
    if gateway.is_none() {
        let runtime = create_gateway(context.inner(), profile.account_id.as_deref()).await?;
        gateway = Some(runtime.status.clone());
        *context.gateway.lock().map_err(error_message)? = Some(runtime);
    }
    profiles::launch(
        &profile,
        gateway.as_ref().map(|status| {
            (
                status.base_url.as_str(),
                status.api_key.as_str(),
                status.route_model.as_deref(),
            )
        }),
    )
    .map(|_| ())
    .map_err(error_message)
}

#[tauri::command]
async fn start_gateway(
    context: tauri::State<'_, Arc<AppContext>>,
) -> Result<GatewayStatus, String> {
    if let Some(status) = context
        .gateway
        .lock()
        .map_err(error_message)?
        .as_ref()
        .map(|runtime| runtime.status.clone())
    {
        return Ok(status);
    }
    let runtime = create_gateway(context.inner(), None).await?;
    let status = runtime.status.clone();
    *context.gateway.lock().map_err(error_message)? = Some(runtime);
    Ok(status)
}

async fn create_gateway(
    context: &Arc<AppContext>,
    preferred_account_id: Option<&str>,
) -> Result<gateway::GatewayRuntime, String> {
    let provider_runtime = if preferred_account_id.is_none() {
        let store = context.store.lock().map_err(error_message)?;
        store
            .config()
            .active_provider_id
            .as_ref()
            .and_then(|id| {
                store
                    .config()
                    .providers
                    .iter()
                    .find(|provider| &provider.id == id)
                    .cloned()
            })
            .map(|provider| {
                let account_id = provider
                    .active_account_id
                    .clone()
                    .ok_or_else(|| "Provider 没有可用账号".to_owned())?;
                let key = store
                    .provider_key(&provider.id, &account_id)
                    .map_err(error_message)?;
                Ok::<_, String>((provider, key))
            })
            .transpose()?
    } else {
        None
    };
    let runtime = if let Some((provider, key)) = provider_runtime {
        gateway::start_provider(provider, key)
            .await
            .map_err(error_message)?
    } else {
        let (account, credentials) = {
            let store = context.store.lock().map_err(error_message)?;
            let account = if let Some(id) = preferred_account_id {
                store.account(id).map_err(error_message)?
            } else {
                store
                    .accounts()
                    .into_iter()
                    .find(|account| account.is_active)
                    .ok_or_else(|| "请先添加并选择一个 OpenAI 账号或 Provider".to_owned())?
            };
            let credentials = store.credentials(&account.id).map_err(error_message)?;
            (account, credentials)
        };
        gateway::start(account, credentials)
            .await
            .map_err(error_message)?
    };
    Ok(runtime)
}

#[tauri::command]
fn create_provider(
    context: tauri::State<'_, Arc<AppContext>>,
    label: String,
    kind: String,
    base_url: String,
    model: String,
    account_label: String,
    api_key: String,
) -> Result<Provider, String> {
    let label = label.trim();
    let model = model.trim();
    let account_label = account_label.trim();
    let parsed = url::Url::parse(base_url.trim()).map_err(error_message)?;
    if label.is_empty() || model.is_empty() || account_label.is_empty() || api_key.trim().is_empty()
    {
        return Err("Provider 名称、模型、账号名称和 API Key 均不能为空".into());
    }
    if !matches!(kind.as_str(), "openAiCompatible" | "openRouter") {
        return Err("Provider 类型无效".into());
    }
    let is_loopback = matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    if parsed.scheme() != "https" && !is_loopback {
        return Err("远程 Provider 必须使用 HTTPS".into());
    }
    let id = slug(label);
    if id.is_empty() {
        return Err("Provider 名称无法生成有效 ID".into());
    }
    context
        .store
        .lock()
        .map_err(error_message)?
        .upsert_provider(
            store::ProviderDraft {
                id,
                label: label.into(),
                kind,
                base_url: base_url.trim_end_matches('/').into(),
                model: model.into(),
                account_label: account_label.into(),
            },
            api_key.trim(),
        )
        .map_err(error_message)
}

#[tauri::command]
fn remove_provider(
    context: tauri::State<'_, Arc<AppContext>>,
    provider_id: String,
) -> Result<(), String> {
    context.gateway.lock().map_err(error_message)?.take();
    context
        .store
        .lock()
        .map_err(error_message)?
        .remove_provider(&provider_id)
        .map_err(error_message)
}

#[tauri::command]
fn set_active_provider(
    context: tauri::State<'_, Arc<AppContext>>,
    provider_id: Option<String>,
) -> Result<(), String> {
    context.gateway.lock().map_err(error_message)?.take();
    context
        .store
        .lock()
        .map_err(error_message)?
        .activate_provider(provider_id)
        .map_err(error_message)
}

#[tauri::command]
fn add_provider_account(
    context: tauri::State<'_, Arc<AppContext>>,
    provider_id: String,
    label: String,
    api_key: String,
) -> Result<Provider, String> {
    if label.trim().is_empty() || api_key.trim().is_empty() {
        return Err("账号名称和 API Key 不能为空".into());
    }
    context
        .store
        .lock()
        .map_err(error_message)?
        .add_provider_account(&provider_id, label.trim().into(), api_key.trim())
        .map_err(error_message)
}

#[tauri::command]
fn remove_provider_account(
    context: tauri::State<'_, Arc<AppContext>>,
    provider_id: String,
    account_id: String,
) -> Result<Provider, String> {
    context.gateway.lock().map_err(error_message)?.take();
    context
        .store
        .lock()
        .map_err(error_message)?
        .remove_provider_account(&provider_id, &account_id)
        .map_err(error_message)
}

#[tauri::command]
fn set_active_provider_account(
    context: tauri::State<'_, Arc<AppContext>>,
    provider_id: String,
    account_id: String,
) -> Result<(), String> {
    context.gateway.lock().map_err(error_message)?.take();
    context
        .store
        .lock()
        .map_err(error_message)?
        .activate_provider_account(&provider_id, &account_id)
        .map_err(error_message)
}

#[tauri::command]
fn set_auto_route(
    context: tauri::State<'_, Arc<AppContext>>,
    enabled: bool,
    threshold: f64,
) -> Result<(), String> {
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_auto_route(enabled, threshold)
        .map_err(error_message)
}

#[tauri::command]
async fn get_records() -> Result<RecordsSnapshot, String> {
    let root = paths::codex_root().map_err(error_message)?.join("sessions");
    tokio::task::spawn_blocking(move || records::snapshot(&root))
        .await
        .map_err(error_message)?
        .map_err(error_message)
}

#[tauri::command]
async fn refresh_theme_market(
    context: tauri::State<'_, Arc<AppContext>>,
    query: String,
) -> Result<ThemePage, String> {
    let sources = context
        .store
        .lock()
        .map_err(error_message)?
        .config()
        .theme_sources
        .clone();
    let (catalog, issues) = themes::refresh_market(&sources).await;
    *context.theme_catalog.lock().map_err(error_message)? = catalog;
    *context.theme_issues.lock().map_err(error_message)? = issues;
    theme_page(context, 0, 24, query)
}

#[tauri::command]
fn theme_page(
    context: tauri::State<'_, Arc<AppContext>>,
    offset: usize,
    limit: usize,
    query: String,
) -> Result<ThemePage, String> {
    let catalog = context.theme_catalog.lock().map_err(error_message)?;
    let issues = context.theme_issues.lock().map_err(error_message)?.clone();
    Ok(themes::paginate(&catalog, issues, offset, limit, &query))
}

#[tauri::command]
fn set_theme_source(
    context: tauri::State<'_, Arc<AppContext>>,
    source_id: String,
    enabled: bool,
) -> Result<(), String> {
    let mut store = context.store.lock().map_err(error_message)?;
    let mut sources = store.config().theme_sources.clone();
    let source = sources
        .iter_mut()
        .find(|source| source.id == source_id)
        .ok_or_else(|| "主题源不存在".to_owned())?;
    source.enabled = enabled;
    store.set_theme_sources(sources).map_err(error_message)
}

#[tauri::command]
fn add_theme_source(
    context: tauri::State<'_, Arc<AppContext>>,
    name: String,
    base_url: String,
) -> Result<ThemeSource, String> {
    let parsed = url::Url::parse(base_url.trim()).map_err(error_message)?;
    if name.trim().is_empty() || parsed.scheme() != "https" {
        return Err("自定义主题源必须有名称并使用 HTTPS".into());
    }
    let source = ThemeSource {
        id: format!("custom-{}", slug(name.trim())),
        name: name.trim().into(),
        base_url: base_url.trim_end_matches('/').into(),
        enabled: true,
        format: "codexPlusPlus".into(),
    };
    let mut store = context.store.lock().map_err(error_message)?;
    let mut sources = store.config().theme_sources.clone();
    sources.retain(|item| item.id != source.id);
    sources.push(source.clone());
    store.set_theme_sources(sources).map_err(error_message)?;
    Ok(source)
}

#[tauri::command]
async fn install_market_theme(
    context: tauri::State<'_, Arc<AppContext>>,
    theme_id: String,
    source_name: String,
) -> Result<(), String> {
    let listing = context
        .theme_catalog
        .lock()
        .map_err(error_message)?
        .iter()
        .find(|item| item.id == theme_id && item.source_name == source_name)
        .cloned()
        .ok_or_else(|| "请先刷新主题市场".to_owned())?;
    install_listing(context.inner(), listing).await
}

#[tauri::command]
async fn install_dreamskin_version(
    context: tauri::State<'_, Arc<AppContext>>,
    version_id: String,
) -> Result<(), String> {
    let listing = themes::fetch_dreamskin_version(&version_id)
        .await
        .map_err(error_message)?;
    install_listing(context.inner(), listing).await
}

async fn install_listing(context: &Arc<AppContext>, listing: ThemeListing) -> Result<(), String> {
    let state = context.store.lock().map_err(error_message)?.theme_state();
    let (installed, _) = themes::install(&listing, &state)
        .await
        .map_err(error_message)?;
    context
        .store
        .lock()
        .map_err(error_message)?
        .install_theme(installed)
        .map_err(error_message)
}

#[tauri::command]
fn import_local_theme(
    context: tauri::State<'_, Arc<AppContext>>,
    directory: String,
) -> Result<ThemeListing, String> {
    let listing = themes::import_local_theme(std::path::Path::new(directory.trim()))
        .map_err(error_message)?;
    context
        .theme_catalog
        .lock()
        .map_err(error_message)?
        .push(listing.clone());
    Ok(listing)
}

#[tauri::command]
async fn apply_theme(
    context: tauri::State<'_, Arc<AppContext>>,
    theme_id: String,
    restart_codex: bool,
) -> Result<(), String> {
    apply_installed_theme(context.inner(), theme_id, restart_codex).await
}

async fn apply_installed_theme(
    context: &Arc<AppContext>,
    theme_id: String,
    restart_codex: bool,
) -> Result<(), String> {
    let state = context.store.lock().map_err(error_message)?.theme_state();
    if !state.installed.iter().any(|theme| theme.id == theme_id) {
        return Err("主题尚未安装".into());
    }
    // 早期 Windows 版本沿用了不会驱动界面配色的 macOS ChromeTheme 表；
    // 先清理它，避免官方桌面端解析旧配置后进入错误页。实际换肤只走 CDP 注入。
    themes::revert_native_colors().map_err(error_message)?;
    let (port, executable) = desktop::ensure_debug_port(&state, restart_codex)
        .await
        .map_err(error_message)?;
    desktop::inject_theme(&theme_id, port)
        .await
        .map_err(error_message)?;
    let mut store = context.store.lock().map_err(error_message)?;
    store
        .set_theme_runtime(Some(executable), Some(port))
        .map_err(error_message)?;
    store
        .set_applied_theme(Some(theme_id))
        .map_err(error_message)
}

#[tauri::command]
async fn revert_theme(context: tauri::State<'_, Arc<AppContext>>) -> Result<(), String> {
    let port = context
        .store
        .lock()
        .map_err(error_message)?
        .theme_state()
        .debug_port;
    if let Some(port) = port {
        let _ = desktop::remove_skin(port).await;
    }
    themes::revert_native_colors().map_err(error_message)?;
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_applied_theme(None)
        .map_err(error_message)
}

#[tauri::command]
fn uninstall_theme(
    context: tauri::State<'_, Arc<AppContext>>,
    theme_id: String,
) -> Result<(), String> {
    if context
        .store
        .lock()
        .map_err(error_message)?
        .theme_state()
        .applied_theme_id
        .as_deref()
        == Some(&theme_id)
    {
        return Err("请先恢复默认主题".into());
    }
    themes::uninstall(&theme_id).map_err(error_message)?;
    context
        .store
        .lock()
        .map_err(error_message)?
        .remove_theme(&theme_id)
        .map_err(error_message)
}

#[tauri::command]
fn set_auto_reapply(
    context: tauri::State<'_, Arc<AppContext>>,
    enabled: bool,
) -> Result<(), String> {
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_auto_reapply(enabled)
        .map_err(error_message)
}

#[tauri::command]
fn set_codex_executable(
    context: tauri::State<'_, Arc<AppContext>>,
    path: String,
) -> Result<(), String> {
    let path = std::path::PathBuf::from(path.trim());
    if path.as_os_str().is_empty() {
        let port = context
            .store
            .lock()
            .map_err(error_message)?
            .theme_state()
            .debug_port;
        return context
            .store
            .lock()
            .map_err(error_message)?
            .set_theme_runtime(None, port)
            .map_err(error_message);
    }
    if !path.is_file()
        || !path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                name.eq_ignore_ascii_case("Codex.exe") || name.eq_ignore_ascii_case("ChatGPT.exe")
            })
    {
        return Err("请选择有效的 Codex.exe 或 ChatGPT.exe".into());
    }
    let port = context
        .store
        .lock()
        .map_err(error_message)?
        .theme_state()
        .debug_port;
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_theme_runtime(Some(path.to_string_lossy().into_owned()), port)
        .map_err(error_message)
}

#[tauri::command]
async fn get_desktop_status(
    context: tauri::State<'_, Arc<AppContext>>,
) -> Result<DesktopStatus, String> {
    let (state, preset) = {
        let store = context.store.lock().map_err(error_message)?;
        (store.theme_state(), store.config().thread_preset.clone())
    };
    let status = desktop::desktop_status(&state, preset).await;
    if status.codex_executable != state.codex_executable || status.debug_port != state.debug_port {
        context
            .store
            .lock()
            .map_err(error_message)?
            .set_theme_runtime(status.codex_executable.clone(), status.debug_port)
            .map_err(error_message)?;
    }
    Ok(status)
}

#[tauri::command]
async fn update_desktop_settings(
    context: tauri::State<'_, Arc<AppContext>>,
    preset: ThreadPreset,
) -> Result<(), String> {
    let state = context.store.lock().map_err(error_message)?.theme_state();
    let status = desktop::desktop_status(&state, preset.clone()).await;
    desktop::update_thread_settings(
        status.debug_port,
        status.conversation_id.as_deref(),
        &preset,
    )
    .await
    .map_err(error_message)?;
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_thread_preset(preset)
        .map_err(error_message)
}

fn slug(value: &str) -> String {
    value
        .trim()
        .to_lowercase()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_owned()
}

async fn poll_usage_once(context: &Arc<AppContext>) {
    let account_ids = match context.store.lock() {
        Ok(store) => store
            .accounts()
            .into_iter()
            .map(|account| account.id)
            .collect::<Vec<_>>(),
        Err(_) => return,
    };
    for account_id in account_ids {
        let pair = match context.store.lock() {
            Ok(store) => store.account(&account_id).and_then(|account| {
                store
                    .credentials(&account_id)
                    .map(|credentials| (account, credentials))
            }),
            Err(_) => return,
        };
        let Ok((mut account, credentials)) = pair else {
            continue;
        };
        match usage::fetch(&account, &credentials).await {
            Ok(snapshot) => {
                account.plan_type = snapshot.plan_type;
                account.primary_used_percent = snapshot.primary_used_percent;
                account.secondary_used_percent = snapshot.secondary_used_percent;
                account.primary_reset_at = snapshot.primary_reset_at;
                account.secondary_reset_at = snapshot.secondary_reset_at;
                account.last_checked = Some(chrono::Utc::now());
                account.token_expired = false;
            }
            Err(error) if error.to_string() == "TOKEN_EXPIRED" => account.token_expired = true,
            Err(_) => continue,
        }
        if let Ok(mut store) = context.store.lock() {
            let _ = store.upsert_account(account, None);
        }
    }
    if let Ok(mut store) = context.store.lock() {
        let _ = store.auto_route_if_needed();
    }
}

#[tauri::command]
fn stop_gateway(context: tauri::State<'_, Arc<AppContext>>) -> Result<(), String> {
    context.gateway.lock().map_err(error_message)?.take();
    Ok(())
}

#[tauri::command]
fn set_start_at_login(
    app: tauri::AppHandle,
    context: tauri::State<'_, Arc<AppContext>>,
    enabled: bool,
) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    let launcher = app.autolaunch();
    if enabled {
        launcher.enable().map_err(error_message)?;
    } else {
        launcher.disable().map_err(error_message)?;
    }
    context
        .store
        .lock()
        .map_err(error_message)?
        .set_start_at_login(enabled)
        .map_err(error_message)
}

#[tauri::command]
async fn check_update(app: tauri::AppHandle) -> Result<Option<update::UpdateInfo>, String> {
    update::check(&app.package_info().version.to_string())
        .await
        .map_err(error_message)
}

#[tauri::command]
fn remove_profile(
    context: tauri::State<'_, Arc<AppContext>>,
    profile_id: String,
) -> Result<(), String> {
    let profile = context
        .store
        .lock()
        .map_err(error_message)?
        .config()
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .cloned()
        .ok_or_else(|| "运行档案不存在".to_owned())?;
    let root = paths::profiles_root().map_err(error_message)?;
    let target = std::path::PathBuf::from(&profile.codex_home)
        .parent()
        .map(std::path::Path::to_path_buf)
        .ok_or_else(|| "运行档案路径无效".to_owned())?;
    if !target.starts_with(&root) {
        return Err("拒绝删除档案根目录之外的路径".into());
    }
    context
        .store
        .lock()
        .map_err(error_message)?
        .remove_profile(&profile_id)
        .map_err(error_message)?;
    if target.exists() {
        std::fs::remove_dir_all(&target).map_err(error_message)?;
    }
    Ok(())
}

fn dreamskin_version(url: &url::Url) -> Option<String> {
    if !url.scheme().eq_ignore_ascii_case("dreamskin") || url.host_str() != Some("apply") {
        return None;
    }
    url.query_pairs()
        .find(|(key, _)| key == "version")
        .map(|(_, value)| value.into_owned())
}

fn handle_deep_links(app: &tauri::AppHandle, urls: Vec<url::Url>) {
    for url in urls {
        let Some(version) = dreamskin_version(&url) else {
            continue;
        };
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.show();
            let _ = window.set_focus();
        }
        let context = app.state::<Arc<AppContext>>().inner().clone();
        let emitter = app.clone();
        tauri::async_runtime::spawn(async move {
            let result = async {
                let listing = themes::fetch_dreamskin_version(&version)
                    .await
                    .map_err(error_message)?;
                let theme_id = listing.id.clone();
                install_listing(&context, listing).await?;
                apply_installed_theme(&context, theme_id, true).await
            }
            .await;
            let message = match result {
                Ok(()) => "DreamSkin 主题已安装并应用".to_owned(),
                Err(error) => format!("DreamSkin 应用失败：{error}"),
            };
            let _ = emitter.emit("theme-applied", message);
        });
    }
}

pub fn run() {
    let store = Store::open_default().expect("无法初始化 codex-box Windows 配置");
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            use tauri_plugin_deep_link::DeepLinkExt;
            app.deep_link().handle_cli_arguments(args.iter());
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::Builder::new().build())
        .plugin(tauri_plugin_deep_link::init())
        .manage(Arc::new(AppContext {
            store: Mutex::new(store),
            oauth: OAuthService::default(),
            gateway: Mutex::new(None),
            theme_catalog: Mutex::new(Vec::new()),
            theme_issues: Mutex::new(Vec::new()),
        }))
        .setup(|app| {
            use tauri::menu::{Menu, MenuItem};
            use tauri::tray::TrayIconBuilder;
            use tauri_plugin_deep_link::DeepLinkExt;
            let show = MenuItem::with_id(app, "show", "打开 codex-box", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            let mut tray = TrayIconBuilder::new().menu(&menu).tooltip("codex-box");
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.on_menu_event(|app, event| match event.id.as_ref() {
                "show" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                "quit" => app.exit(0),
                _ => {}
            })
            .build(app)?;

            let deep_link_app = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                handle_deep_links(&deep_link_app, event.urls());
            });
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                handle_deep_links(app.handle(), urls);
            }

            let restore_context = app.state::<Arc<AppContext>>().inner().clone();
            let restore_emitter = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let state = match restore_context.store.lock() {
                    Ok(store) => store.theme_state(),
                    Err(_) => return,
                };
                let Some(theme_id) = state
                    .applied_theme_id
                    .clone()
                    .filter(|_| state.auto_reapply)
                else {
                    return;
                };
                if let Err(error) = apply_installed_theme(&restore_context, theme_id, false).await {
                    let _ =
                        restore_emitter.emit("theme-applied", format!("主题自动恢复失败：{error}"));
                }
            });

            let polling_context = app.state::<Arc<AppContext>>().inner().clone();
            let polling_emitter = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                loop {
                    poll_usage_once(&polling_context).await;
                    let _ = polling_emitter.emit("dashboard-changed", ());
                    tokio::time::sleep(std::time::Duration::from_secs(300)).await;
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_dashboard,
            start_oauth,
            complete_oauth,
            refresh_usage,
            set_active_account,
            remove_account,
            export_accounts,
            import_accounts,
            create_profile,
            launch_profile,
            remove_profile,
            start_gateway,
            stop_gateway,
            set_start_at_login,
            check_update,
            create_provider,
            remove_provider,
            set_active_provider,
            add_provider_account,
            remove_provider_account,
            set_active_provider_account,
            set_auto_route,
            get_records,
            refresh_theme_market,
            theme_page,
            set_theme_source,
            add_theme_source,
            install_market_theme,
            install_dreamskin_version,
            import_local_theme,
            apply_theme,
            revert_theme,
            uninstall_theme,
            set_auto_reapply,
            set_codex_executable,
            get_desktop_status,
            update_desktop_settings
        ])
        .run(tauri::generate_context!())
        .expect("codex-box Windows 运行失败");
}

#[cfg(test)]
mod tests {
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn callback_listener_rejects_wrong_path() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let receive = tokio::spawn(super::receive_callback(listener));
        let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
        stream
            .write_all(b"GET /wrong HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .unwrap();
        assert!(receive.await.unwrap().is_err());
    }

    #[test]
    fn dreamskin_link_requires_the_apply_host_and_version() {
        let valid = url::Url::parse("dreamskin://apply?version=ver_123").unwrap();
        assert_eq!(super::dreamskin_version(&valid).as_deref(), Some("ver_123"));
        let wrong_host = url::Url::parse("dreamskin://delete?version=ver_123").unwrap();
        assert!(super::dreamskin_version(&wrong_host).is_none());
        let missing_version = url::Url::parse("dreamskin://apply").unwrap();
        assert!(super::dreamskin_version(&missing_version).is_none());
    }
}
