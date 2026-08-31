# codex-box Windows

这是独立的 Tauri 2 + Rust Windows 系统托盘版本，不影响仓库中的 macOS Swift 工程。

## 功能

- OpenAI PKCE OAuth 登录与 `localhost:1455` 自动回调
- OAuth Token 存入 Windows Credential Manager，公开配置不包含敏感凭据
- 只读查询 ChatGPT Codex 用量，不在后台轮换共享 refresh token
- 扫描 `~/.codex/sessions` 统计 Token 与估算成本
- 使用独立 `CODEX_HOME` 启动 Codex CLI 运行档案
- 仅监听 `127.0.0.1` 的 Responses 流式账号网关
- 系统托盘、关闭到托盘、开机启动和 GitHub Release 更新检查
- NSIS `.exe` 与 WiX `.msi` 安装包

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
pnpm tauri build --bundles nsis,msi
```

安装包输出到 `src-tauri/target/release/bundle/`。完整 Windows 构建也可通过仓库的“Windows 构建与测试”工作流执行。

## 数据与安全

- 公开配置：`%USERPROFILE%\.codex-box\windows-config.json`
- 隔离运行档案：`%USERPROFILE%\.codex-box\profiles\<id>\codex-home`
- OAuth 凭据：Windows Credential Manager

应用不会通过账号切换写入 `%USERPROFILE%\.codex\auth.json`。本地网关使用随机密钥并只绑定回环地址；停止网关或退出应用后端口立即关闭。
