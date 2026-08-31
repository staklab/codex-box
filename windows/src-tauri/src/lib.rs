mod cost;
mod gateway;
mod models;
mod oauth;
mod paths;
mod profiles;
mod store;
mod update;
mod usage;

use models::{Account, CostSummary, GatewayStatus, Profile};
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Dashboard {
    accounts: Vec<Account>,
    profiles: Vec<Profile>,
    cost: CostSummary,
    gateway: Option<GatewayStatus>,
    start_at_login: bool,
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
    let (accounts, profiles, start_at_login) = {
        let store = context.store.lock().map_err(error_message)?;
        (
            store.accounts(),
            store.config().profiles.clone(),
            store.config().start_at_login,
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
fn launch_profile(
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
    let gateway = context
        .gateway
        .lock()
        .map_err(error_message)?
        .as_ref()
        .map(|runtime| runtime.status.clone());
    profiles::launch(
        &profile,
        gateway
            .as_ref()
            .map(|status| (status.base_url.as_str(), status.api_key.as_str())),
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
    let (account, credentials) = {
        let store = context.store.lock().map_err(error_message)?;
        let account = store
            .accounts()
            .into_iter()
            .find(|account| account.is_active)
            .ok_or_else(|| "请先添加并选择一个 OpenAI 账号".to_owned())?;
        let credentials = store.credentials(&account.id).map_err(error_message)?;
        (account, credentials)
    };
    let runtime = gateway::start(account, credentials)
        .await
        .map_err(error_message)?;
    let status = runtime.status.clone();
    *context.gateway.lock().map_err(error_message)? = Some(runtime);
    Ok(status)
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

pub fn run() {
    let store = Store::open_default().expect("无法初始化 codex-box Windows 配置");
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::Builder::new().build())
        .manage(Arc::new(AppContext {
            store: Mutex::new(store),
            oauth: OAuthService::default(),
            gateway: Mutex::new(None),
        }))
        .setup(|app| {
            use tauri::menu::{Menu, MenuItem};
            use tauri::tray::TrayIconBuilder;
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
            create_profile,
            launch_profile,
            remove_profile,
            start_gateway,
            stop_gateway,
            set_start_at_login,
            check_update
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
}
