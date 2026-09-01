# codex-box Windows

这是独立的 Tauri 2 + Rust Windows 系统托盘版本，不影响仓库中的 macOS Swift 工程。

## 功能

- OpenAI PKCE OAuth 登录与 `localhost:1455` 自动回调
- OAuth Token 存入 Windows Credential Manager，公开配置不包含敏感凭据
- 只读查询 ChatGPT Codex 用量，不在后台轮换共享 refresh token
- rhino2api JSON、旧版 CSV、手动 OAuth callback/code 导入
- 扫描 `~/.codex/sessions`，按会话和模型展示 Token、时间与估算成本
- 使用独立 `CODEX_HOME` 启动 Codex CLI 运行档案
- OpenAI Compatible、OpenRouter Provider 与多密钥账号切换
- 仅监听 `127.0.0.1` 的 Responses 流式账号/Provider 网关
- 用量达到阈值后自动选择剩余用量更多的 OAuth 账号
- 自动识别运行中的 `Codex.exe`/`ChatGPT.exe`、PATH、常见安装目录与 Appx 安装包，通过随机回环 CDP 端口热注入 CSS 和壁纸
- 当前会话或新会话默认的模型、推理强度、Service tier、上下文窗口设置
- CodexPlusPlus Themes、DreamSkin.cc、Awesome Codex Skins、自定义 HTTPS 源与本地主题
- `dreamskin://apply?version=...` 一键安装应用、启动链接补读与单实例转发
- 系统托盘、关闭到托盘和开机启动
- 启动后自动检查 GitHub Release、应用内后台下载并校验安装包，安装重启前单独确认
- NSIS `.exe` 与 WiX `.msi` 安装包

## 主题稳定性与安全

- 市场每页最多渲染 24 张卡片，后端单页硬限制 48；DreamSkin 最多预取 5 页
- 窗口采用单一滚动区，头部、导航和底部不会随大量主题反复重排
- 页面首次打开后保留挂载与独立滚动位置，提示使用浮层展示，不触发布局和窗口尺寸变化
- 主题包最大 64 MiB，壁纸注入最大 32 MiB
- `.codexskin` 使用完整 SHA-256/首次安装摘要校验，并拒绝 ZIP 路径穿越
- 会话默认参数修改 `config.toml` 前创建备份，采用临时文件替换并在失败时回滚；主题视觉只通过 CDP 注入
- CDP 只绑定 `127.0.0.1` 随机端口，客户端明确绕过系统代理

## 本地开发

```powershell
cd windows
pnpm install
pnpm tauri dev
```

## 测试与构建

```powershell
pnpm lint
pnpm test
pnpm build
cargo test --manifest-path src-tauri/Cargo.toml
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
pnpm tauri build --bundles nsis,msi
```

安装包输出到 `src-tauri/target/release/bundle/`。完整 Windows 构建也可通过仓库的“Windows 构建与测试”工作流执行。

## 数据与安全

- 公开配置：`%USERPROFILE%\.codex-box\windows-config.json`
- 隔离运行档案：`%USERPROFILE%\.codex-box\profiles\<id>\codex-home`
- 已安装主题：`%USERPROFILE%\.codex-box\themes`
- OAuth 与 Provider 凭据：Windows Credential Manager

应用不会通过账号切换写入 `%USERPROFILE%\.codex\auth.json`。本地网关使用随机密钥并只绑定回环地址；停止网关或退出应用后端口立即关闭。
