use crate::config_edit;
use crate::models::{DesktopStatus, ThemeColors, ThemeState, ThreadPreset};
use crate::{paths, themes};
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CdpTarget {
    #[serde(rename = "type")]
    kind: String,
    url: Option<String>,
    web_socket_debugger_url: Option<String>,
}

pub fn find_codex_executable(configured: Option<&str>) -> Option<PathBuf> {
    if let Some(path) = configured
        .map(PathBuf::from)
        .filter(|path| path.is_file() && is_supported_executable(path))
    {
        return Some(path);
    }
    if let Some(path) = find_running_desktop_executable() {
        return Some(path);
    }
    let mut candidates = candidate_paths(
        std::env::var_os("LOCALAPPDATA").as_deref(),
        std::env::var_os("ProgramFiles").as_deref(),
        std::env::var_os("ProgramFiles(x86)").as_deref(),
    );
    candidates.extend(find_executables_on_path());
    candidates
        .into_iter()
        .find(|path| path.is_file() && is_supported_executable(path))
        .or_else(find_packaged_desktop_executable)
}

fn candidate_paths(
    local: Option<&std::ffi::OsStr>,
    program_files: Option<&std::ffi::OsStr>,
    program_files_x86: Option<&std::ffi::OsStr>,
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(local) = local {
        candidates.extend([
            PathBuf::from(local).join("Programs/Codex/Codex.exe"),
            PathBuf::from(local).join("OpenAI/Codex/Codex.exe"),
            PathBuf::from(local).join("Programs/OpenAI Codex/Codex.exe"),
            PathBuf::from(local).join("Programs/ChatGPT/ChatGPT.exe"),
            PathBuf::from(local).join("OpenAI/ChatGPT/ChatGPT.exe"),
            PathBuf::from(local).join("Programs/OpenAI ChatGPT/ChatGPT.exe"),
            PathBuf::from(local).join("Microsoft/WindowsApps/Codex.exe"),
            PathBuf::from(local).join("Microsoft/WindowsApps/ChatGPT.exe"),
        ]);
    }
    for root in [program_files, program_files_x86].into_iter().flatten() {
        candidates.extend([
            PathBuf::from(root).join("Codex/Codex.exe"),
            PathBuf::from(root).join("OpenAI/Codex/Codex.exe"),
            PathBuf::from(root).join("ChatGPT/ChatGPT.exe"),
            PathBuf::from(root).join("OpenAI/ChatGPT/ChatGPT.exe"),
        ]);
    }
    candidates
}

fn is_supported_executable(path: &Path) -> bool {
    let supported_name = path.file_name().and_then(|name| name.to_str()).is_some_and(|name| {
        name.eq_ignore_ascii_case("Codex.exe") || name.eq_ignore_ascii_case("ChatGPT.exe")
    });
    let Some(parent) = path.parent() else { return false };
    // Windows 文件名不区分大小写；后台 CLI codex.exe 不能作为 Electron 桌面启动。
    supported_name && path.is_file() && parent.join("icudtl.dat").is_file()
        && (parent.join("resources/app.asar").is_file()
            || parent.join("resources/app/package.json").is_file())
}

#[cfg(target_os = "windows")]
fn hidden_output(program: &str, args: &[&str]) -> Option<std::process::Output> {
    use std::os::windows::process::CommandExt;
    Command::new(program)
        .args(args)
        .creation_flags(0x08000000)
        .output()
        .ok()
        .filter(|output| output.status.success())
}

#[cfg(target_os = "windows")]
fn powershell_lines(script: &str) -> Vec<String> {
    hidden_output(
        "powershell.exe",
        &[
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &format!("[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); {script}"),
        ],
    )
    .map(|output| {
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect()
    })
    .unwrap_or_default()
}

#[cfg(target_os = "windows")]
fn find_running_desktop_executable() -> Option<PathBuf> {
    powershell_lines("Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('Codex.exe','ChatGPT.exe') -and $_.ExecutablePath } | Select-Object -ExpandProperty ExecutablePath -Unique")
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.is_file() && is_supported_executable(path))
}

#[cfg(not(target_os = "windows"))]
fn find_running_desktop_executable() -> Option<PathBuf> {
    None
}

#[cfg(target_os = "windows")]
fn find_executables_on_path() -> Vec<PathBuf> {
    ["Codex.exe", "ChatGPT.exe"]
        .into_iter()
        .filter_map(|name| hidden_output("where.exe", &[name]))
        .flat_map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(|line| PathBuf::from(line.trim()))
                .collect::<Vec<_>>()
        })
        .collect()
}

#[cfg(not(target_os = "windows"))]
fn find_executables_on_path() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "windows")]
fn find_packaged_desktop_executable() -> Option<PathBuf> {
    powershell_lines("Get-AppxPackage | Where-Object { $_.Name -match 'ChatGPT|Codex|OpenAI' } | ForEach-Object { Get-ChildItem -LiteralPath $_.InstallLocation -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('Codex.exe','ChatGPT.exe') } | Select-Object -ExpandProperty FullName }")
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.is_file() && is_supported_executable(path))
}

#[cfg(not(target_os = "windows"))]
fn find_packaged_desktop_executable() -> Option<PathBuf> {
    None
}

pub async fn ensure_debug_port(state: &ThemeState, restart: bool) -> anyhow::Result<(u16, String)> {
    if let Some(port) = state.debug_port {
        if healthy_main_target(port).await.is_ok() {
            let executable = find_codex_executable(state.codex_executable.as_deref())
                .map(|path| path.to_string_lossy().into_owned())
                .unwrap_or_default();
            return Ok((port, executable));
        }
    }
    for port in find_running_debug_ports() {
        if healthy_main_target(port).await.is_ok() {
            let executable = find_codex_executable(state.codex_executable.as_deref())
                .map(|path| path.to_string_lossy().into_owned())
                .unwrap_or_default();
            return Ok((port, executable));
        }
    }
    let executable = find_codex_executable(state.codex_executable.as_deref())
        .ok_or_else(|| anyhow::anyhow!("未自动识别到 Codex Desktop，请确认已经安装或正在运行"))?;
    if desktop_process_is_running(&executable) && !restart {
        anyhow::bail!("Codex Desktop 正在以普通模式运行；请在主题页确认一次安全重启后再换肤")
    }
    if restart {
        stop_exact_codex_process(&executable)?;
        tokio::time::sleep(Duration::from_millis(1_200)).await;
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    let mut command = Command::new(&executable);
    command
        .arg(format!("--remote-debugging-port={port}"))
        .arg("--remote-debugging-address=127.0.0.1")
        .arg(format!("--remote-allow-origins=http://127.0.0.1:{port}"))
        .env(
            "NO_PROXY",
            merge_no_proxy(std::env::var("NO_PROXY").ok().as_deref()),
        )
        .env(
            "no_proxy",
            merge_no_proxy(std::env::var("no_proxy").ok().as_deref()),
        );
    if let Some(parent) = executable.parent() {
        command.current_dir(parent);
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command.spawn()?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    let mut last_error = String::new();
    while tokio::time::Instant::now() < deadline {
        match healthy_main_target(port).await {
            Ok(_) => return Ok((port, executable.to_string_lossy().into_owned())),
            Err(error) => last_error = error.to_string(),
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    anyhow::bail!("Codex 换肤连接未在 45 秒内就绪：{last_error}")
}

#[cfg(target_os = "windows")]
fn desktop_process_query(executable: &Path) -> String {
    let quoted = executable.to_string_lossy().replace('\'', "''");
    format!("Get-CimInstance Win32_Process | Where-Object {{ $_.ExecutablePath -eq '{quoted}' }}")
}

#[cfg(target_os = "windows")]
fn stop_exact_codex_process(executable: &Path) -> anyhow::Result<()> {
    if !is_supported_executable(executable) {
        anyhow::bail!("仅允许重启已验证的 Codex Desktop，不能重启同名 CLI")
    }
    // 只请求此安装路径的窗口正常退出，避免 /IM Codex.exe 误杀其他会话的后台服务。
    let script = format!("{} | ForEach-Object {{ $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($p) {{ $null = $p.CloseMainWindow() }} }}", desktop_process_query(executable));
    powershell_lines(&script);
    let deadline = std::time::Instant::now() + Duration::from_secs(8);
    while std::time::Instant::now() < deadline {
        if !desktop_process_is_running(executable) { return Ok(()) }
        std::thread::sleep(Duration::from_millis(250));
    }
    // Windows 桌面可能把关闭窗口解释为隐藏到后台。调用方已获得重启确认；
    // 只终止已验证路径的主进程树，绝不能按 Codex.exe 名称操作其他 CLI。
    let roots = powershell_lines(&format!("{} | Where-Object {{ $_.CommandLine -notmatch '(?:^|\\s)--type=' }} | Select-Object -ExpandProperty ProcessId", desktop_process_query(executable)));
    for pid in roots.iter().filter_map(|value| value.parse::<u32>().ok()) {
        hidden_output("taskkill.exe", &["/PID", &pid.to_string(), "/T", "/F"]);
    }
    for _ in 0..20 {
        if !desktop_process_is_running(executable) { return Ok(()) }
        std::thread::sleep(Duration::from_millis(250));
    }
    anyhow::bail!("Codex Desktop 未能完全退出，请保存任务并手动关闭后重试")
}

#[cfg(not(target_os = "windows"))]
fn stop_exact_codex_process(_executable: &Path) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(target_os = "windows")]
fn desktop_process_is_running(executable: &Path) -> bool {
    !powershell_lines(&format!("{} | Select-Object -ExpandProperty ProcessId", desktop_process_query(executable))).is_empty()
}

#[cfg(not(target_os = "windows"))]
fn desktop_process_is_running(_executable: &Path) -> bool {
    false
}

#[cfg(target_os = "windows")]
fn find_running_debug_ports() -> Vec<u16> {
    powershell_lines("Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('Codex.exe','ChatGPT.exe') -and $_.CommandLine } | Select-Object -ExpandProperty CommandLine")
        .iter().filter_map(|line| parse_debug_port(line)).collect()
}

#[cfg(not(target_os = "windows"))]
fn find_running_debug_ports() -> Vec<u16> { Vec::new() }

#[cfg(any(target_os = "windows", test))]
fn parse_debug_port(command_line: &str) -> Option<u16> {
    let marker = "--remote-debugging-port";
    let remainder = command_line.split(marker).nth(1)?.trim_start();
    let remainder = remainder
        .strip_prefix('=')
        .unwrap_or(remainder)
        .trim_start();
    let digits: String = remainder
        .chars()
        .take_while(|character| character.is_ascii_digit())
        .collect();
    digits.parse().ok().filter(|port| *port > 0)
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
    let candidates: Vec<_> = targets.into_iter().filter(|target| {
        target.url.as_deref().and_then(|value| url::Url::parse(value).ok()).is_some_and(|url|
            url.scheme() == "app" && url.host_str() == Some("-") && url.path() == "/index.html")
    }).collect();
    let mut states = Vec::new();
    for target in &candidates {
        let state = tokio::time::timeout(Duration::from_secs(2), evaluate_target_inner(target,
            include_str!("../../../codexBar/Resources/desktop-window-focus.js"), false)).await;
        let state = state.ok().and_then(Result::ok).unwrap_or(Value::Null);
        states.push((state["focused"].as_bool().unwrap_or(false), state["lastFocus"].as_f64().unwrap_or(0.0)));
    }
    if candidates.len() == 1 { return Ok(candidates[0].clone()); }
    if let Some(index) = active_window_index(&states) { return Ok(candidates[index].clone()); }
    anyhow::bail!("请先点击需要控制的 Codex 窗口，再打开 codex-box")
}

fn active_window_index(states: &[(bool, f64)]) -> Option<usize> {
    let focused: Vec<_> = states.iter().enumerate().filter(|(_, s)| s.0).map(|(i, _)| i).collect();
    if focused.len() == 1 { return Some(focused[0]); }
    if !focused.is_empty() { return None; }
    let latest = states.iter().map(|s| s.1).fold(0.0_f64, f64::max);
    let matches: Vec<_> = states.iter().enumerate().filter(|(_, s)| s.1 == latest && latest > 0.0).map(|(i, _)| i).collect();
    if matches.len() == 1 { Some(matches[0]) } else { None }
}

#[cfg(test)]
fn select_main_target(targets: Vec<CdpTarget>) -> anyhow::Result<CdpTarget> {
    targets.into_iter().find(|target| {
        target.url.as_deref().and_then(|url| url::Url::parse(url).ok()).is_some_and(|url| {
            url.scheme() == "app" && url.host_str() == Some("-") && url.path() == "/index.html"
        })
    }).ok_or_else(|| anyhow::anyhow!("找不到 Codex 桌面主窗口，辅助窗口不能用于换肤"))
}

async fn healthy_main_target(port: u16) -> anyhow::Result<CdpTarget> {
    let target = main_target(port).await?;
    let health = evaluate_target(
        &target,
        "(() => { if(document.readyState==='loading'||!document.body) return 'loading'; const shell=document.querySelector('.app-shell-left-panel,main,[data-app-shell-main-surface]'); const text=(document.body.innerText||'').toLowerCase(); if(!shell && (text.includes('hit a snag')||text.includes('something went wrong')||text.includes('遇到问题'))) return 'error-page'; return (window.electronBridge||window.__codexRoot) && document.body.children.length ? 'ready':'loading'; })()",
        false,
    )
    .await?;
    match health.as_str() {
        Some("ready") => Ok(target),
        Some("error-page") => anyhow::bail!("Codex Desktop 启动到了错误页，请先正常重启官方应用"),
        _ => anyhow::bail!("Codex Desktop 页面仍在加载"),
    }
}

async fn evaluate_target(
    target: &CdpTarget,
    expression: &str,
    await_promise: bool,
) -> anyhow::Result<Value> {
    tokio::time::timeout(Duration::from_secs(if expression.contains("const timeoutMs=60000;") {65} else {20}), evaluate_target_inner(target, expression, await_promise))
        .await.map_err(|_| anyhow::anyhow!("Codex 调试连接超时"))?
}

async fn evaluate_target_inner(target: &CdpTarget, expression: &str, await_promise: bool) -> anyhow::Result<Value> {
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
        "(() => {{ const css=new TextDecoder().decode(Uint8Array.from(atob('{}'),c=>c.charCodeAt(0))); let el=document.getElementById('codexbox-skin'); if(!el){{el=document.createElement('style');el.id='codexbox-skin';document.documentElement.appendChild(el);}} el.textContent=css; return el.isConnected && el.sheet && el.sheet.cssRules.length > 0 ? 'ok' : 'failed'; }})()",
        encoded
    );
    let target = healthy_main_target(port).await?;
    if evaluate_target(&target, &script, false).await?.as_str() != Some("ok") {
        anyhow::bail!("主题样式未成功加载")
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
.app-shell-left-panel,main.bg-surface,main[class*="_MainContentSurface_"],header[class*="h-toolbar"]{{background:transparent!important;border-color:transparent!important;backdrop-filter:none!important}}
[class*="_ComposerLayoutRoot_"],[class*="_ComposerLayoutBody_"]{{background:transparent!important}}
.electron-light [class*="_ComposerLayoutRoot_"]{{background:rgba(248,250,249,.28)!important;backdrop-filter:blur(10px) saturate(.9)!important}}
.electron-dark [class*="_ComposerLayoutRoot_"]{{background:rgba(18,20,20,.16)!important;backdrop-filter:blur(6px) saturate(.9)!important}}
[class*="_ComposerLayoutRoot_"].gap-2{{border-radius:25px!important;overflow:hidden!important}}
[class*="_MainContentTopFade_"]{{display:none!important;background:none!important}}
.app-shell-left-panel::after{{content:none!important;background:transparent!important}}
.electron-light .app-shell-left-panel,.electron-light main[class*="_MainContentSurface_"],.electron-light header[class*="h-toolbar"]{{background:rgba(248,250,249,.10)!important;text-shadow:none!important}}
.electron-light{{--color-text-primary:#18232b!important;--color-text-secondary:#1c252e!important;--color-text-tertiary:#1c252e!important}}
.electron-light [class*="_ComposerLayoutRoot_"]{{background:rgba(248,250,249,.76)!important;backdrop-filter:none!important}}
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
            "html,body{{background:transparent!important}}body::before{{content:'';position:fixed;inset:0;z-index:0;pointer-events:none;background-image:url(\"data:{mime};base64,{}\");background-size:cover;background-position:center}}.electron-light body::before{{filter:saturate(1.05)}}.electron-dark body::before{{filter:brightness(.55) saturate(.9)}}",
            STANDARD.encode(bytes)
        ));
        break;
    }
    Ok(css)
}

pub async fn desktop_status(state: &ThemeState, fallback: ThreadPreset) -> DesktopStatus {
    let executable = find_codex_executable(state.codex_executable.as_deref())
        .map(|path| path.to_string_lossy().into_owned());
    let port = match state.debug_port {
        Some(port) if healthy_main_target(port).await.is_ok() => Some(port),
        _ => {
            let mut live = None;
            for candidate in find_running_debug_ports() {
                if healthy_main_target(candidate).await.is_ok() { live = Some(candidate); break }
            }
            live
        }
    };
    let Some(port) = port else {
        return DesktopStatus {
            connected: false,
            target: if executable.is_some() {
                "已识别，等待换肤连接".into()
            } else {
                "未识别到安装".into()
            },
            conversation_id: None,
            preset: read_global_preset().unwrap_or(fallback),
            codex_executable: executable,
            debug_port: None,
        };
    };
    let snapshot = async {
        let (target, id, _) = current_route(port).await?;
        let mut preset = if let Some(id) = &id { read_thread_preset(port, id).await? }
            else { read_global_preset().unwrap_or(fallback.clone()) };
        let (_, confirmed_id, tier) = current_route(port).await?;
        anyhow::ensure!(id == confirmed_id, "当前对话正在切换");
        if let Some(tier) = tier { preset.service_tier = tier; }
        else if id.is_some() { preset.service_tier = "unknown".into(); }
        Ok::<_, anyhow::Error>((target, id, preset))
    }.await;
    match snapshot {
        Ok((target, conversation_id, preset)) => DesktopStatus {
            connected: true,
            target,
            preset,
            conversation_id,
            codex_executable: executable,
            debug_port: Some(port),
        },
        Err(error) => DesktopStatus {
            connected: false,
            target: format!("会话控制不可用：{error}"),
            conversation_id: None,
            preset: read_global_preset().unwrap_or(fallback),
            codex_executable: executable,
            debug_port: Some(port),
        },
    }
}

async fn current_route(port: u16) -> anyhow::Result<(String, Option<String>, Option<String>)> {
    let script = include_str!("../../../codexBar/Resources/desktop-thread-route.js");
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
        _ => anyhow::bail!("无法唯一识别当前本地对话"),
    };
    let tier = if route["serviceTierKnown"] == true {
        Some(match route["serviceTier"].as_str().unwrap_or("default") {
            "priority" => "fast",
            value => value,
        }.to_owned())
    } else { None };
    Ok((target, conversation, tier))
}

pub async fn update_thread_settings(
    port: Option<u16>,
    conversation_id: Option<&str>,
    preset: &ThreadPreset,
) -> anyhow::Result<()> {
    let port = port.ok_or_else(|| anyhow::anyhow!("会话控制未连接"))?;
    let (_, current_id, previous_tier) = current_route(port).await?;
    anyhow::ensure!(current_id.as_deref() == conversation_id, "当前对话已变化，请刷新后再修改");
    if let Some(thread_id) = conversation_id {
        let previous = read_thread_preset(port, thread_id).await?;
        anyhow::ensure!(preset.context_window == previous.context_window,
            "Codex 不支持在线修改已加载对话的上下文窗口");
        anyhow::ensure!(!preset.model.trim().is_empty(), "模型不能为空");
        let mut params = json!({"threadId": thread_id, "model": preset.model});
        let changed_tier = preset.service_tier != "unknown" && previous_tier.as_deref() != Some(&preset.service_tier);
        if changed_tier { params["serviceTier"] = json!(preset.service_tier); }
        anyhow::ensure!(preset.reasoning_effort != "default" || previous.reasoning_effort == "default",
            "请明确选择思考强度；当前协议的空值会保留原设置");
        if preset.reasoning_effort != "default" {
            params["effort"] = json!(preset.reasoning_effort);
        }
        send_desktop_request(port, "thread/settings/update", params).await?;
        let actual = read_thread_preset(port, thread_id).await?;
        anyhow::ensure!(actual.model == preset.model && actual.reasoning_effort == preset.reasoning_effort,
            "Codex 返回设置与请求不一致，请刷新后重试");
        let (_, confirmed_id, confirmed_tier) = current_route(port).await?;
        anyhow::ensure!(confirmed_id.as_deref() == Some(thread_id),
            "设置已发送到原对话，但当前页面已切换，请刷新查看");
        anyhow::ensure!(!changed_tier || confirmed_tier.as_deref() == Some(&preset.service_tier),
            "Codex 尚未确认速度模式，请刷新后查看");
    } else {
        validate_preset(preset)?;
        write_global_preset(preset)?;
    }
    Ok(())
}

async fn read_thread_preset(port: u16, thread_id: &str) -> anyhow::Result<ThreadPreset> {
    let result = send_desktop_request(port, "thread/read",
        json!({"threadId": thread_id, "includeTurns": false})).await?;
    let thread = &result["thread"];
    anyhow::ensure!(thread["id"].as_str() == Some(thread_id), "Codex 返回的对话不匹配");
    let model = thread["model"].as_str().filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow::anyhow!("Codex 未返回真实模型设置"))?;
    let record = read_branch_record(thread_id).ok().flatten();
    let after = record.as_ref().and_then(|r| r["createdAt"].as_str());
    let context = thread["path"].as_str().and_then(|path| actual_context_window(path, model, after)).unwrap_or(0);
    Ok(ThreadPreset { model: model.into(),
        reasoning_effort: thread["reasoningEffort"].as_str().unwrap_or("default").into(),
        service_tier: "unknown".into(), context_window: context })
}

fn actual_context_window(path: &str, model: &str, after: Option<&str>) -> Option<u64> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(size.saturating_sub(4 * 1024 * 1024))).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let tail = String::from_utf8_lossy(&bytes);
    let mut window = None;
    for line in tail.lines().rev() {
        let Ok(event) = serde_json::from_str::<Value>(line) else { continue };
        if let Some(after) = after {
            let cutoff = chrono::DateTime::parse_from_rfc3339(after).ok();
            let timestamp = event["timestamp"].as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            if cutoff.is_none() || timestamp.is_none() || timestamp <= cutoff { continue; }
        }
        if event["type"] == "turn_context" {
            return if event["payload"]["model"] == model { window } else { None };
        }
        if window.is_none() && event["type"] == "event_msg" && event["payload"]["type"] == "token_count" {
            window = event["payload"]["info"]["model_context_window"].as_u64().filter(|n| *n > 0);
        }
    }
    None
}

async fn send_desktop_request(port: u16, method: &str, params: Value) -> anyhow::Result<Value> {
    let request = json!({"method": method, "params": params});
    let encoded = STANDARD.encode(serde_json::to_vec(&request)?);
    let timeout_ms = if method == "thread/fork" { 60000 } else { 10000 };
    let script = format!(
        r#"(() => new Promise((resolve) => {{const payload=JSON.parse(atob('{encoded}'));const timeoutMs={timeout_ms};const requestId=`codex-box-${{Date.now()}}-${{Math.random().toString(16).slice(2)}}`;let finished=false;const finish=(value)=>{{if(finished)return;finished=true;window.removeEventListener('message',listener);clearTimeout(timer);resolve(JSON.stringify(value))}};const listener=(event)=>{{const envelope=event.data;const response=envelope?.message??envelope?.response;if(envelope?.type!=='mcp-response'||String(response?.id)!==requestId)return;if(response.error)finish({{ok:false,error:response.error}});else {{let result=response.result??{{}};if(payload.method==='thread/fork')result={{thread:{{id:result.thread?.id}},model:result.model,reasoningEffort:result.reasoningEffort}};finish({{ok:true,result}})}}}};const timer=setTimeout(()=>finish({{ok:false,error:{{message:'Codex 桌面请求超时'}}}}),timeoutMs+2000);window.addEventListener('message',listener);window.electronBridge.sendMessageFromView({{type:'mcp-request',hostId:'local',priority:'critical',source:'thread',timeoutMs,expiresAtMs:Date.now()+timeoutMs,request:{{id:requestId,method:payload.method,params:payload.params}}}}).catch(error=>finish({{ok:false,error:{{message:String(error)}}}}))}}))()"#
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


pub fn context_info(model: &str, conversation_id: Option<&str>) -> anyhow::Result<Value> {
    let catalog: Value = std::fs::read(paths::codex_root()?.join("models_cache.json")).ok()
        .and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or(Value::Null);
    let entry = catalog["models"].as_array().and_then(|models| models.iter().find(|entry| entry["slug"] == model));
    let maximum = entry.and_then(|e| e["max_context_window"].as_u64());
    let percent = entry.and_then(|e| e["effective_context_window_percent"].as_u64()).filter(|p| (1..=100).contains(p));
    let saved = conversation_id.and_then(|id| read_branch_record(id).ok().flatten());
    Ok(json!({"maximum":maximum,"percent":percent,"configured":saved.map(|v|v["window"].clone())}))
}

fn read_branch_record(id: &str) -> anyhow::Result<Option<Value>> {
    let id = uuid::Uuid::parse_str(id)?;
    let path = paths::app_root()?.join("context-branches").join(format!("{id}.json"));
    if !path.exists() { return Ok(None); }
    Ok(Some(serde_json::from_slice(&std::fs::read(path)?)?))
}

static FORKING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub async fn create_context_branch(port: u16, source: &str, window: u64) -> anyhow::Result<String> {
    let _guard = FORKING.try_lock().map_err(|_| anyhow::anyhow!("分支正在创建，请勿重复提交"))?;
    anyhow::ensure!((16000..=2000000).contains(&window), "上下文配置超出范围");
    uuid::Uuid::parse_str(source)?;
    anyhow::ensure!(current_route(port).await?.1.as_deref() == Some(source), "当前对话已变化");
    let read = send_desktop_request(port, "thread/read", json!({"threadId":source,"includeTurns":false})).await?;
    anyhow::ensure!(read["thread"]["id"] == source && read["thread"]["status"]["type"] == "idle", "请等待原对话生成完成");
    anyhow::ensure!(current_route(port).await?.1.as_deref() == Some(source), "当前对话已变化");
    let result = send_desktop_request(port, "thread/fork", json!({"threadId":source,"excludeTurns":true,"config":{"model_context_window":window}})).await?;
    let id = result["thread"]["id"].as_str().ok_or_else(||anyhow::anyhow!("Codex 未返回新分支 ID"))?;
    let parsed = uuid::Uuid::parse_str(id)?;
    anyhow::ensure!(id != source, "返回的分支 ID 与原对话相同");
    let root = paths::app_root()?.join("context-branches");
    std::fs::create_dir_all(&root)?;
    std::fs::write(root.join(format!("{parsed}.json")), serde_json::to_vec(&json!({"window":window,"createdAt":chrono::Utc::now().to_rfc3339()}))?)
        .map_err(|e| anyhow::anyhow!("分支已创建（{id}），保存配置失败：{e}"))?;
    if current_route(port).await?.1.as_deref() == Some(source) {
        let script = format!("window.postMessage({{type:'navigate-to-route',path:{}}},'*');true",serde_json::to_string(&format!("/local/{id}"))?);
        evaluate_target(&main_target(port).await?, &script, false).await
            .map_err(|e|anyhow::anyhow!("分支已创建（{id}），请从会话列表打开：{e}"))?;
    }
    Ok(id.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_selection_and_query_routes() {
        assert_eq!(active_window_index(&[(false,10.0),(false,20.0)]),Some(1));
        assert_eq!(active_window_index(&[(true,10.0),(false,20.0)]),Some(0));
        assert_eq!(active_window_index(&[(false,0.0),(false,0.0)]),None);
        assert_eq!(active_window_index(&[(false,20.0),(false,20.0)]),None);
        let target = CdpTarget { kind:"page".into(),url:Some("app://-/index.html?initialRoute=%2Flocal%2Fbranch".into()),web_socket_debugger_url:Some("ws://127.0.0.1/fixture".into()) };
        assert!(select_main_target(vec![target]).is_ok());
    }

    #[test]
    fn context_window_belongs_to_latest_turn_model() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("rollout.jsonl");
        std::fs::write(&path, concat!(
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"old\"}}\n",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"model_context_window\":258400}}}\n"
        )).unwrap();
        assert_eq!(actual_context_window(path.to_str().unwrap(), "old", None), Some(258400));
        assert_eq!(actual_context_window(path.to_str().unwrap(), "new", None), None);
    }

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

    #[test]
    fn supports_both_desktop_executable_names() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("resources")).unwrap();
        for name in ["Codex.exe", "ChatGPT.exe", "codex-box.exe"] {
            std::fs::write(root.path().join(name), b"exe").unwrap();
        }
        assert!(!is_supported_executable(&root.path().join("Codex.exe")), "同名 CLI 必须被排除");
        std::fs::write(root.path().join("icudtl.dat"), b"icu").unwrap();
        std::fs::write(root.path().join("resources/app.asar"), b"app").unwrap();
        assert!(is_supported_executable(&root.path().join("Codex.exe")));
        assert!(is_supported_executable(&root.path().join("ChatGPT.exe")));
        assert!(!is_supported_executable(&root.path().join("codex-box.exe")));
    }

    #[test]
    fn parses_debug_port_from_windows_command_line() {
        assert_eq!(
            parse_debug_port(r#"ChatGPT.exe --remote-debugging-port=54321"#),
            Some(54321)
        );
        assert_eq!(
            parse_debug_port(r#"Codex.exe --remote-debugging-port 49152"#),
            Some(49152)
        );
        assert_eq!(parse_debug_port("Codex.exe"), None);
    }

    #[test]
    fn automatic_candidates_include_chatgpt_and_codex() {
        let paths = candidate_paths(
            Some(std::ffi::OsStr::new("C:/Users/test/AppData/Local")),
            Some(std::ffi::OsStr::new("C:/Program Files")),
            None,
        );
        assert!(paths.iter().any(|path| path.ends_with("Codex.exe")));
        assert!(paths.iter().any(|path| path.ends_with("ChatGPT.exe")));
    }
}

#[cfg(all(test, target_os = "windows"))]
#[path = "desktop/windows_skin_tests.rs"]
mod windows_skin_tests;
