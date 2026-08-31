use crate::config_edit;
use crate::models::{DesktopStatus, ThemeColors, ThemeState, ThreadPreset};
use crate::{paths, themes};
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CdpTarget {
    #[serde(rename = "type")]
    kind: String,
    title: Option<String>,
    url: Option<String>,
    web_socket_debugger_url: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadPresetFile {
    #[serde(default)]
    threads: HashMap<String, ThreadPreset>,
}

pub fn find_codex_executable(configured: Option<&str>) -> Option<PathBuf> {
    if let Some(path) = configured.map(PathBuf::from).filter(|path| path.is_file()) {
        return Some(path);
    }
    let mut candidates = Vec::new();
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        candidates.extend([
            PathBuf::from(&local).join("Programs/Codex/Codex.exe"),
            PathBuf::from(&local).join("OpenAI/Codex/Codex.exe"),
            PathBuf::from(&local).join("Programs/OpenAI Codex/Codex.exe"),
        ]);
    }
    for variable in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Ok(root) = std::env::var(variable) {
            candidates.extend([
                PathBuf::from(&root).join("Codex/Codex.exe"),
                PathBuf::from(&root).join("OpenAI/Codex/Codex.exe"),
            ]);
        }
    }
    candidates.into_iter().find(|path| path.is_file())
}

pub async fn ensure_debug_port(state: &ThemeState, restart: bool) -> anyhow::Result<(u16, String)> {
    if let Some(port) = state.debug_port {
        if !page_targets(port).await.unwrap_or_default().is_empty() {
            let executable = state.codex_executable.clone().unwrap_or_default();
            return Ok((port, executable));
        }
    }
    let executable = find_codex_executable(state.codex_executable.as_deref())
        .ok_or_else(|| anyhow::anyhow!("未找到 Codex.exe，请在桌面设置中填写程序路径"))?;
    if restart {
        stop_exact_codex_process(&executable)?;
        tokio::time::sleep(Duration::from_millis(600)).await;
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    let mut command = Command::new(&executable);
    command
        .arg(format!("--remote-debugging-port={port}"))
        .arg(format!("--remote-allow-origins=http://127.0.0.1:{port}"))
        .env(
            "NO_PROXY",
            merge_no_proxy(std::env::var("NO_PROXY").ok().as_deref()),
        )
        .env(
            "no_proxy",
            merge_no_proxy(std::env::var("no_proxy").ok().as_deref()),
        );
    command.spawn()?;
    for _ in 0..60 {
        if !page_targets(port).await.unwrap_or_default().is_empty() {
            return Ok((port, executable.to_string_lossy().into_owned()));
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    anyhow::bail!("Codex 调试端口未在 15 秒内就绪")
}

#[cfg(target_os = "windows")]
fn stop_exact_codex_process(executable: &Path) -> anyhow::Result<()> {
    let name = executable
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow::anyhow!("Codex 程序路径无效"))?;
    if !name.eq_ignore_ascii_case("Codex.exe") {
        anyhow::bail!("仅允许重启 Codex.exe")
    }
    let _ = Command::new("taskkill")
        .args(["/IM", name, "/T", "/F"])
        .output();
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn stop_exact_codex_process(_executable: &Path) -> anyhow::Result<()> {
    Ok(())
}

fn merge_no_proxy(existing: Option<&str>) -> String {
    let mut values: Vec<&str> = existing
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .collect();
    for required in ["127.0.0.1", "localhost", "::1"] {
        if !values
            .iter()
            .any(|value| value.eq_ignore_ascii_case(required))
        {
            values.push(required);
        }
    }
    values.join(",")
}

async fn page_targets(port: u16) -> anyhow::Result<Vec<CdpTarget>> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()?;
    let targets: Vec<CdpTarget> = client
        .get(format!("http://127.0.0.1:{port}/json"))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    Ok(targets
        .into_iter()
        .filter(|target| target.kind == "page" && target.web_socket_debugger_url.is_some())
        .collect())
}

async fn main_target(port: u16) -> anyhow::Result<CdpTarget> {
    let targets = page_targets(port).await?;
    targets
        .iter()
        .find(|target| {
            let title = target.title.as_deref().unwrap_or_default().to_lowercase();
            let url = target.url.as_deref().unwrap_or_default();
            title.contains("codex") || url.contains("index.html")
        })
        .cloned()
        .or_else(|| targets.into_iter().next())
        .ok_or_else(|| anyhow::anyhow!("找不到 Codex 桌面主窗口"))
}

async fn evaluate_target(
    target: &CdpTarget,
    expression: &str,
    await_promise: bool,
) -> anyhow::Result<Value> {
    let url = target
        .web_socket_debugger_url
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("CDP 目标缺少 WebSocket 地址"))?;
    let (mut socket, _) = tokio_tungstenite::connect_async(url).await?;
    let payload = json!({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {
            "expression": expression,
            "awaitPromise": await_promise,
            "returnByValue": true
        }
    });
    socket
        .send(Message::Text(payload.to_string().into()))
        .await?;
    while let Some(message) = socket.next().await {
        let message = message?;
        let text = match message {
            Message::Text(text) => text.to_string(),
            Message::Binary(bytes) => String::from_utf8(bytes.to_vec())?,
            _ => continue,
        };
        let response: Value = serde_json::from_str(&text)?;
        if response.get("id").and_then(Value::as_u64) != Some(1) {
            continue;
        }
        if let Some(error) = response.get("error") {
            anyhow::bail!("CDP 执行失败：{error}")
        }
        if let Some(exception) = response.pointer("/result/exceptionDetails") {
            anyhow::bail!("Codex 页面脚本失败：{exception}")
        }
        return Ok(response
            .pointer("/result/result/value")
            .cloned()
            .unwrap_or(Value::Null));
    }
    anyhow::bail!("CDP 连接提前关闭")
}

pub async fn inject_theme(id: &str, port: u16) -> anyhow::Result<()> {
    let (colors, directory) = themes::load_definition(id)?;
    let css = build_css(&colors, &directory)?;
    let encoded = STANDARD.encode(css.as_bytes());
    let script = format!(
        "(() => {{ const css=atob('{}'); let el=document.getElementById('codexbox-skin'); if(!el){{el=document.createElement('style');el.id='codexbox-skin';document.documentElement.appendChild(el);}} el.textContent=css; return 'ok'; }})()",
        encoded
    );
    let targets = page_targets(port).await?;
    if targets.is_empty() {
        anyhow::bail!("Codex 调试目标不可用")
    }
    for target in &targets {
        evaluate_target(target, &script, false).await?;
    }
    Ok(())
}

pub async fn remove_skin(port: u16) -> anyhow::Result<()> {
    let script = "(() => { const el=document.getElementById('codexbox-skin'); if(el) el.remove(); return 'removed'; })()";
    for target in page_targets(port).await? {
        evaluate_target(&target, script, false).await?;
    }
    Ok(())
}

fn build_css(colors: &ThemeColors, directory: &Path) -> anyhow::Result<String> {
    let mut accents = Vec::new();
    if let Some(value) = normalized_hex(colors.accent.as_deref()) {
        accents.push(format!("--wb-focus:{value}!important;"));
    }
    if let Some(value) = normalized_hex(colors.secondary.as_deref()) {
        accents.push(format!(
            "--diffs-addition-color-override:{value}!important;"
        ));
    }
    if let Some(value) = normalized_hex(colors.highlight.as_deref()) {
        accents.push(format!(
            "--diffs-deletion-color-override:{value}!important;"
        ));
    }
    let mut css = format!(
        r#"
.electron-dark{{--codexbox-scrim:rgba(24,24,24,.52);--codexbox-scrim-2:rgba(20,20,20,.60)}}
.electron-light{{--codexbox-scrim:rgba(245,245,247,.62);--codexbox-scrim-2:rgba(240,240,242,.70)}}
:root,.electron-dark,.electron-light{{--wb-surface-primary:var(--codexbox-scrim)!important;--color-background-surface:var(--codexbox-scrim)!important;--wb-surface-secondary:var(--codexbox-scrim-2)!important;--color-background-surface-under:var(--codexbox-scrim-2)!important;{}}}
aside.app-shell-left-panel,main.bg-surface,main[class*="_MainContentSurface_"],header[class*="h-toolbar"]{{background:transparent!important;border-color:transparent!important;backdrop-filter:none!important}}
[class*="_ComposerLayoutRoot_"],[class*="_ComposerLayoutBody_"]{{background:transparent!important}}
.electron-light [class*="_ComposerLayoutRoot_"]{{background:rgba(248,250,249,.28)!important;backdrop-filter:blur(10px) saturate(.9)!important}}
.electron-dark [class*="_ComposerLayoutRoot_"]{{background:rgba(18,20,20,.16)!important;backdrop-filter:blur(6px) saturate(.9)!important}}
[class*="_ComposerLayoutRoot_"].gap-2{{border-radius:25px!important;overflow:hidden!important}}
[class*="_MainContentTopFade_"]{{display:none!important;background:none!important}}
body::after{{content:none!important}}
"#,
        accents.join("")
    );
    for name in ["image.png", "image.jpg", "image.jpeg", "image.webp"] {
        let path = directory.join(name);
        if !path.exists() {
            continue;
        }
        let bytes = std::fs::read(&path)?;
        if bytes.len() > 32 * 1024 * 1024 {
            anyhow::bail!("壁纸超过 32 MiB 注入限制")
        }
        let mime = if name.ends_with(".png") {
            "image/png"
        } else if name.ends_with(".webp") {
            "image/webp"
        } else {
            "image/jpeg"
        };
        css.push_str(&format!(
            "html,body{{background:transparent!important}}body::before{{content:'';position:fixed;inset:0;z-index:0;pointer-events:none;background-image:url(\"data:{mime};base64,{}\");background-size:cover;background-position:center}}.electron-light body::before{{filter:contrast(.82) saturate(.9)}}.electron-dark body::before{{filter:brightness(.55) saturate(.9)}}",
            STANDARD.encode(bytes)
        ));
        break;
    }
    Ok(css)
}

pub async fn desktop_status(state: &ThemeState, fallback: ThreadPreset) -> DesktopStatus {
    let executable = find_codex_executable(state.codex_executable.as_deref())
        .map(|path| path.to_string_lossy().into_owned());
    let Some(port) = state.debug_port else {
        return DesktopStatus {
            connected: false,
            target: "未连接".into(),
            conversation_id: None,
            preset: read_global_preset().unwrap_or(fallback),
            codex_executable: executable,
            debug_port: None,
        };
    };
    match current_route(port).await {
        Ok((target, conversation_id)) => DesktopStatus {
            connected: true,
            target,
            preset: preset_for_thread(conversation_id.as_deref())
                .unwrap_or_else(|| read_global_preset().unwrap_or(fallback)),
            conversation_id,
            codex_executable: executable,
            debug_port: Some(port),
        },
        Err(_) => DesktopStatus {
            connected: false,
            target: "未连接".into(),
            conversation_id: None,
            preset: read_global_preset().unwrap_or(fallback),
            codex_executable: executable,
            debug_port: Some(port),
        },
    }
}

async fn current_route(port: u16) -> anyhow::Result<(String, Option<String>)> {
    let script = r#"(() => {const root=window.__codexRoot?._internalRoot?.current;if(!root)return JSON.stringify({routeKind:'unavailable',conversationID:null});const routes=[],seenFibers=new Set(),seenObjects=new WeakSet(),stack=[root];const scan=(value,depth=0)=>{if(depth>5||value==null||typeof value!=='object'||seenObjects.has(value))return;seenObjects.add(value);try{if(typeof value.routeKind==='string')routes.push({routeKind:value.routeKind,conversationID:typeof value.conversationId==='string'?value.conversationId:null});for(const key of Object.keys(value).slice(0,100)){if(/children|return|child|sibling|stateNode|alternate|_owner/i.test(key))continue;scan(value[key],depth+1)}}catch(_){}};let count=0;while(stack.length&&count<50000){const fiber=stack.pop();if(!fiber||seenFibers.has(fiber))continue;seenFibers.add(fiber);count++;scan(fiber.memoizedProps);scan(fiber.pendingProps);scan(fiber.memoizedState);if(fiber.child)stack.push(fiber.child);if(fiber.sibling)stack.push(fiber.sibling)}const active=routes.find(route=>route.routeKind==='local-thread'&&route.conversationID);if(active)return JSON.stringify(active);const home=routes.find(route=>route.routeKind==='home'||route.routeKind==='new-thread-panel');return JSON.stringify(home??{routeKind:'unavailable',conversationID:null})})()"#;
    let value = evaluate_target(&main_target(port).await?, script, false).await?;
    let route: Value = serde_json::from_str(value.as_str().unwrap_or("{}"))?;
    let kind = route
        .get("routeKind")
        .and_then(Value::as_str)
        .unwrap_or("unavailable");
    let conversation = route
        .get("conversationID")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let target = match (kind, conversation.as_deref()) {
        ("local-thread", Some(id)) => format!("当前对话 · {}", &id[..id.len().min(8)]),
        ("home" | "new-thread-panel", _) => "新对话默认".into(),
        _ => "未识别当前页面".into(),
    };
    Ok((target, conversation))
}

pub async fn update_thread_settings(
    port: Option<u16>,
    conversation_id: Option<&str>,
    preset: &ThreadPreset,
) -> anyhow::Result<()> {
    validate_preset(preset)?;
    if let (Some(port), Some(thread_id)) = (port, conversation_id) {
        let params = json!({
            "threadId": thread_id,
            "model": preset.model,
            "reasoningEffort": preset.reasoning_effort,
            "serviceTier": preset.service_tier,
        });
        send_desktop_request(port, "thread/settings/update", params).await?;
        send_desktop_request(
            port,
            "thread/resume",
            json!({"threadId": thread_id, "config": {"model_context_window": preset.context_window}}),
        )
        .await?;
        persist_thread_preset(thread_id, preset)?;
    } else {
        write_global_preset(preset)?;
    }
    Ok(())
}

fn preset_for_thread(thread_id: Option<&str>) -> Option<ThreadPreset> {
    let thread_id = thread_id?;
    let data = std::fs::read(paths::thread_presets_path().ok()?).ok()?;
    let file: ThreadPresetFile = serde_json::from_slice(&data).ok()?;
    file.threads.get(thread_id).cloned()
}

fn persist_thread_preset(thread_id: &str, preset: &ThreadPreset) -> anyhow::Result<()> {
    let path = paths::thread_presets_path()?;
    let mut file = std::fs::read(&path)
        .ok()
        .and_then(|data| serde_json::from_slice::<ThreadPresetFile>(&data).ok())
        .unwrap_or_default();
    file.threads.insert(thread_id.to_owned(), preset.clone());
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, serde_json::to_vec_pretty(&file)?)?;
    Ok(())
}

async fn send_desktop_request(port: u16, method: &str, params: Value) -> anyhow::Result<Value> {
    let request = json!({"method": method, "params": params});
    let encoded = STANDARD.encode(serde_json::to_vec(&request)?);
    let script = format!(
        r#"(() => new Promise((resolve) => {{const payload=JSON.parse(atob('{encoded}'));const requestId=`codex-box-${{Date.now()}}-${{Math.random().toString(16).slice(2)}}`;let finished=false;const finish=(value)=>{{if(finished)return;finished=true;window.removeEventListener('message',listener);clearTimeout(timer);resolve(JSON.stringify(value))}};const listener=(event)=>{{const envelope=event.data;const response=envelope?.message??envelope?.response;if(envelope?.type!=='mcp-response'||String(response?.id)!==requestId)return;if(response.error)finish({{ok:false,error:response.error}});else finish({{ok:true,result:response.result??{{}}}})}};const timer=setTimeout(()=>finish({{ok:false,error:{{message:'Codex 桌面请求超时'}}}}),12000);window.addEventListener('message',listener);window.electronBridge.sendMessageFromView({{type:'mcp-request',hostId:'local',priority:'critical',source:'thread',timeoutMs:10000,expiresAtMs:Date.now()+10000,request:{{id:requestId,method:payload.method,params:payload.params}}}}).catch(error=>finish({{ok:false,error:{{message:String(error)}}}}))}}))()"#
    );
    let value = evaluate_target(&main_target(port).await?, &script, true).await?;
    let envelope: Value = serde_json::from_str(value.as_str().unwrap_or("{}"))?;
    if envelope.get("ok").and_then(Value::as_bool) != Some(true) {
        anyhow::bail!(
            "{}",
            envelope
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("Codex 桌面请求失败")
        )
    }
    Ok(envelope.get("result").cloned().unwrap_or(Value::Null))
}

fn read_global_preset() -> Option<ThreadPreset> {
    let text = std::fs::read_to_string(paths::codex_config_path().ok()?).ok()?;
    Some(ThreadPreset {
        model: unquote(config_edit::root_value(&text, "model"))
            .unwrap_or_else(|| "gpt-5.6-sol".into()),
        reasoning_effort: unquote(config_edit::root_value(&text, "model_reasoning_effort"))
            .unwrap_or_else(|| "medium".into()),
        service_tier: unquote(config_edit::root_value(&text, "service_tier"))
            .unwrap_or_else(|| "flex".into()),
        context_window: config_edit::root_value(&text, "model_context_window")
            .and_then(|value| value.parse().ok())
            .unwrap_or(272_000),
    })
}

fn write_global_preset(preset: &ThreadPreset) -> anyhow::Result<()> {
    let path = paths::codex_config_path()?;
    let original = std::fs::read_to_string(&path).unwrap_or_default();
    let mut updated =
        config_edit::upsert_root_key(&original, "model", &format!("\"{}\"", preset.model));
    updated = config_edit::upsert_root_key(
        &updated,
        "model_reasoning_effort",
        &format!("\"{}\"", preset.reasoning_effort),
    );
    updated = config_edit::upsert_root_key(
        &updated,
        "service_tier",
        &format!("\"{}\"", preset.service_tier),
    );
    updated = config_edit::upsert_root_key(
        &updated,
        "model_context_window",
        &preset.context_window.to_string(),
    );
    config_edit::write_with_backup(&path, &updated, "config.toml.bak-codexbox-settings")
}

fn unquote(value: Option<String>) -> Option<String> {
    let value = value?;
    Some(value.trim().trim_matches('"').to_owned())
}

fn validate_preset(preset: &ThreadPreset) -> anyhow::Result<()> {
    if preset.model.trim().is_empty()
        || !matches!(
            preset.reasoning_effort.as_str(),
            "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
        )
        || !matches!(
            preset.service_tier.as_str(),
            "auto" | "default" | "flex" | "priority"
        )
        || !(16_000..=2_000_000).contains(&preset.context_window)
    {
        anyhow::bail!("线程设置参数无效")
    }
    Ok(())
}

fn normalized_hex(value: Option<&str>) -> Option<String> {
    let value = value?.trim().trim_start_matches('#');
    if (value.len() == 6 || value.len() == 8)
        && value.chars().all(|character| character.is_ascii_hexdigit())
    {
        Some(format!("#{}", value.to_lowercase()))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_proxy_always_contains_loopback() {
        let value = merge_no_proxy(Some("example.com,localhost"));
        assert!(value.contains("127.0.0.1"));
        assert_eq!(value.matches("localhost").count(), 1);
    }

    #[test]
    fn preset_validation_rejects_dangerous_values() {
        let preset = ThreadPreset {
            model: "".into(),
            ..Default::default()
        };
        assert!(validate_preset(&preset).is_err());
    }
}
