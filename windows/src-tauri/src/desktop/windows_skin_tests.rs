//! 在 Windows CI 使用真实 Electron/CDP 与独立 CLI 进程验证换肤链路。
use super::*;

const WALLPAPER_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAACI0lEQVR4nA3RoarAIBQA0Pc5Ly4ajcZF48KCmExiMMgw3DCGwSBj4QYRg0HkBdO+7e0DTjo/v7tZdkt2R3fPdlj3k+9h26PYk9ofs6PbM+w17C3tHfe/n19pFmmJdFR6JmGVJ5dhk1HIpORjJDqZQdYgW5Id5QeUWZQlylHlmYJVnVyFTUWhklKPUehUBlWDakl1VB/QZtGWaEe1ZxpWfXIdNh2FTko/RqPTGXQNuiXdUX/AmsVaYh21nllY7clt2GwUNin7GIvOZrA12JZsR/uBwyyHJYejh2cHrMfJj7AdURxJHY850B0ZjhqOlo6OxwfALGAJOAqeAaxwcggbRAFJwWMAHWSAGqAl6AgfuMxyWXI5enl2wXqd/ArbFcWV1PWYC92V4arhaunqeH0gmiVaEh2NnkVY48lj2GIUMan4mIguZog1xJZix/iB2yy3Jbejt2c3rPfJ77DdUdxJ3Y+50d0Z7hrulu6O9wfQLGgJOoqeIax4cgwbRoFJ4WMQHWbAGrAl7IgfKGYplhRHi2cF1nLyErYSRUmqPKagKxlKDaWl0rF8oJmlWdIcbZ41WNvJW9haFN9se0xD1zK0GlpLrWP7wDDLsGQ4OjwbsI6Tj7CNKEZS4zED3cgwahgtjY7jA9Ms05Lp6PRswjpPPsM2o5hJzcdMdDPDrGG2NDvOD7xmeS15HX09e2F9T/6G7Y3iTep9zIvuzfDW8Lb0dnz//gFmX4sQgThjagAAAABJRU5ErkJggg==";

struct ChildGuard(std::process::Child);
impl Drop for ChildGuard {
    fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
}
struct DesktopGuard(PathBuf);
impl Drop for DesktopGuard {
    fn drop(&mut self) { let _ = stop_exact_codex_process(&self.0); }
}

async fn cdp(target: &CdpTarget, method: &str, params: Value) -> Value {
    tokio::time::timeout(Duration::from_secs(15), async {
        let (mut ws, _) = tokio_tungstenite::connect_async(target.web_socket_debugger_url.as_deref().unwrap()).await.unwrap();
        ws.send(Message::Text(json!({"id":7,"method":method,"params":params}).to_string().into())).await.unwrap();
        while let Some(message) = ws.next().await {
            let message = message.unwrap();
            if let Message::Text(text) = message {
                let reply: Value = serde_json::from_str(&text).unwrap();
                if reply["id"] == 7 { assert!(reply.get("error").is_none(), "{reply}"); return reply["result"].clone(); }
            }
        }
        panic!("CDP 连接提前关闭")
    }).await.expect("CDP 测试超时")
}

#[tokio::test]
#[ignore = "由 Windows 工作流准备独立 Electron 与 CLI 后运行"]
async fn windows_skin_end_to_end() {
    assert_eq!(std::env::var("CI").as_deref(), Ok("true"), "仅在隔离 CI 运行");
    let desktop = PathBuf::from(std::env::var("CODEX_BOX_E2E_DESKTOP").unwrap());
    let cli = PathBuf::from(std::env::var("CODEX_BOX_E2E_CLI").unwrap());
    let artifacts = PathBuf::from(std::env::var("CODEX_BOX_E2E_ARTIFACTS").unwrap());
    std::fs::create_dir_all(&artifacts).unwrap();
    assert!(is_supported_executable(&desktop));
    assert!(!is_supported_executable(&cli));
    let mut sentinel = ChildGuard(Command::new(&cli).spawn().unwrap());
    let _desktop_guard = DesktopGuard(desktop.clone());
    let ordinary = Command::new(&desktop).spawn().unwrap();
    let ordinary_pid = ordinary.id();
    let _ordinary_guard = ChildGuard(ordinary);
    tokio::time::sleep(Duration::from_secs(4)).await;
    let mut state = ThemeState { codex_executable: Some(desktop.to_string_lossy().into()), debug_port: Some(9), ..Default::default() };
    assert!(ensure_debug_port(&state, false).await.is_err(), "失效连接需要确认重启");
    let (port, found) = ensure_debug_port(&state, true).await.unwrap();
    assert_eq!(PathBuf::from(found), desktop);
    assert!(sentinel.0.try_wait().unwrap().is_none(), "重启桌面不能误杀同名 CLI");
    assert_ne!(port, 9);
    // 错误缓存路径不能把后台 CLI 当桌面；应找到实际运行的 Electron。
    assert_eq!(find_codex_executable(cli.to_str()), Some(desktop.clone()));
    state.debug_port = Some(port);
    assert_eq!(ensure_debug_port(&state, false).await.unwrap().0, port);
    let target = healthy_main_target(port).await.unwrap();
    assert_eq!(target.url.as_deref(), Some("app://-/index.html"));
    let overlay = page_targets(port).await.unwrap().into_iter().find(|t| t.url.as_deref()==Some("app://-/avatar-overlay")).unwrap();
    assert!(select_main_target(vec![overlay.clone()]).is_err());
    assert!(select_main_target(vec![overlay.clone(), target.clone()]).is_ok());
    let theme_id = format!("skin-e2e-{}", uuid::Uuid::new_v4());
    let dir = paths::themes_root().unwrap().join(&theme_id);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("theme.json"), br##"{"colors":{"accent":"#308050"}}"##).unwrap();
    std::fs::write(dir.join("image.png"), STANDARD.decode(WALLPAPER_BASE64).unwrap()).unwrap();
    for mode in ["dark", "light"] {
        evaluate_target(&target, &format!("document.documentElement.className='electron-{mode}'"), false).await.unwrap();
        inject_theme(&theme_id, port).await.unwrap();
        inject_theme(&theme_id, port).await.unwrap();
        let data = evaluate_target(&target, r#"(() => {const panel=document.querySelector('.app-shell-left-panel');const r=document.querySelector('#click').getBoundingClientRect();return {count:document.querySelectorAll('#codexbox-skin').length,after:getComputedStyle(panel,'::after').content,image:getComputedStyle(document.body,'::before').backgroundImage,x:r.x+r.width/2,y:r.y+r.height/2,probes:window.probes}})()"#, false).await.unwrap();
        assert_eq!(data["count"], 1); assert_eq!(data["after"], "none");
        assert!(data["image"].as_str().unwrap().contains("data:image/png;base64,"));
        assert!(data["probes"].as_u64().unwrap()<5);
        let before = evaluate_target(&target, "window.clicks", false).await.unwrap().as_u64().unwrap();
        for kind in ["mousePressed", "mouseReleased"] {
            cdp(&target,"Input.dispatchMouseEvent",json!({"type":kind,"x":data["x"],"y":data["y"],"button":"left","clickCount":1})).await;
        }
        assert_eq!(evaluate_target(&target,"window.clicks",false).await.unwrap().as_u64().unwrap(),before+1);
        assert_eq!(evaluate_target(&overlay,"document.querySelectorAll('#codexbox-skin').length",false).await.unwrap(),0);
        let shot=cdp(&target,"Page.captureScreenshot",json!({"format":"png"})).await;
        std::fs::write(artifacts.join(format!("windows-skin-{mode}.png")),STANDARD.decode(shot["data"].as_str().unwrap()).unwrap()).unwrap();
    }
    remove_skin(port).await.unwrap();
    assert_eq!(evaluate_target(&target,"document.querySelectorAll('#codexbox-skin').length",false).await.unwrap(),0);
    assert!(sentinel.0.try_wait().unwrap().is_none());
    std::fs::remove_dir_all(dir).unwrap();
    std::fs::write(artifacts.join("result.json"),json!({"passed":true,"ordinaryPid":ordinary_pid,"port":port,"cliPreserved":true,"modes":["dark","light"],"repeatApply":true,"physicalClick":true,"restore":true,"overlayUntouched":true}).to_string()).unwrap();
}

#[tokio::test]
#[ignore = "由 Windows 工作流安装官方 MSIX 后运行；使用 CI 空白登录环境"]
async fn official_windows_skin_startup() {
    assert_eq!(std::env::var("CI").as_deref(), Ok("true"));
    let desktop=PathBuf::from(std::env::var("CODEX_BOX_E2E_OFFICIAL").unwrap());
    let artifacts=PathBuf::from(std::env::var("CODEX_BOX_E2E_ARTIFACTS").unwrap());
    std::fs::create_dir_all(&artifacts).unwrap();
    assert!(is_supported_executable(&desktop));
    let _guard=DesktopGuard(desktop.clone());
    let state=ThemeState{codex_executable:Some(desktop.to_string_lossy().into()),..Default::default()};
    let (port,_)=match ensure_debug_port(&state,true).await {
        Ok(runtime) => runtime,
        Err(error) => {
            for port in find_running_debug_ports() {
                if let Ok(target) = main_target(port).await {
                    if let Ok(text) = evaluate_target(&target, "document.body?.innerText", false).await {
                        std::fs::write(artifacts.join("official-startup-error.json"), text.to_string()).unwrap();
                    }
                    let shot = cdp(&target,"Page.captureScreenshot",json!({"format":"png"})).await;
                    std::fs::write(artifacts.join("official-startup-error.png"),STANDARD.decode(shot["data"].as_str().unwrap()).unwrap()).unwrap();
                }
            }
            panic!("官方客户端启动失败：{error}");
        }
    };
    let target=healthy_main_target(port).await.unwrap();
    let screenshot=cdp(&target,"Page.captureScreenshot",json!({"format":"png"})).await;
    std::fs::write(artifacts.join("official-before.png"),STANDARD.decode(screenshot["data"].as_str().unwrap()).unwrap()).unwrap();
    let theme_id=format!("official-e2e-{}",uuid::Uuid::new_v4());
    let dir=paths::themes_root().unwrap().join(&theme_id);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("theme.json"),br##"{"colors":{"accent":"#308050"}}"##).unwrap();
    // 有效的 PNG，使用上一个测试同款程序化壁纸。
    std::fs::write(dir.join("image.png"),STANDARD.decode(WALLPAPER_BASE64).unwrap()).unwrap();
    inject_theme(&theme_id,port).await.unwrap();
    tokio::time::sleep(Duration::from_secs(8)).await;
    healthy_main_target(port).await.unwrap();
    let style=evaluate_target(&target,"document.getElementById('codexbox-skin')?.sheet?.cssRules.length",false).await.unwrap();
    assert!(style.as_u64().unwrap_or(0)>0);
    let screenshot=cdp(&target,"Page.captureScreenshot",json!({"format":"png"})).await;
    std::fs::write(artifacts.join("official-after.png"),STANDARD.decode(screenshot["data"].as_str().unwrap()).unwrap()).unwrap();
    remove_skin(port).await.unwrap();
    healthy_main_target(port).await.unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    std::fs::write(artifacts.join("official-result.json"),json!({"passed":true,"version":std::env::var("CODEX_BOX_E2E_OFFICIAL_VERSION").unwrap(),"startup":true,"injection":true,"restore":true,"authenticatedSession":false}).to_string()).unwrap();
}
