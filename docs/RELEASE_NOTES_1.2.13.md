# codex-box 1.2.13

本版本为 macOS 与 Windows 补齐应用内自动更新，并保留聚合网关下的账号无感切换与会话连续性。

## 自动更新

- 应用启动后自动检查 GitHub Release，之后每 24 小时复查
- 发现新版本后先询问是否后台下载，下载期间可继续使用
- 下载完成后校验 GitHub Release 提供的 SHA-256 摘要
- 安装和重启前再次询问，可选择稍后处理
- macOS 在应用内完成 DMG 挂载、应用验证、替换与重新启动
- Windows 在应用内完成 NSIS/MSI 下载、校验、静默安装与重新启动
- Windows 只识别 Release 中匹配平台的 NSIS/MSI 安装包

## 账号切换与聚合

- 恢复应用或网关重启前最近使用的会话账号绑定
- 正在运行的会话优先沿用原账号，不因本地配额快照提前迁移
- 原账号收到真实账号级失败后，自动切换至可用账号并继续转发同一请求
- 切换时保留 thread 标识、请求正文与 `previous_response_id`，确保上下文连续
- 成功切换后持久化新的会话账号归属，后续请求继续使用新账号

## 安装包

- `codex-box-1.2.13-macOS.dmg`：同时支持 Apple Silicon 与 Intel Mac
- Windows NSIS `.exe`：推荐安装包，可用于后续无感更新
- Windows WiX `.msi`：企业部署备用安装包

macOS 安装包采用 ad-hoc 签名且未做 Apple 公证。首次启动若被 Gatekeeper 阻止，请在“系统设置 → 隐私与安全性”中确认允许打开。

## 完整性

`codex-box-1.2.13-macOS.dmg` SHA-256：

```text
83584e9e1c520893d4b3016e272d766581ee64b0b2ec0ae9b62492d11c170354
```
