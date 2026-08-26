# codex-box 1.2.8

codex-box 的首个公开版本，面向需要与官方 Codex Desktop 长期共存的 macOS 用户。

## 平台

- 仅支持 macOS 13 或更高版本
- 安装包为通用架构 DMG，同时支持 Apple Silicon 与 Intel Mac
- 暂不提供 Windows 或 Linux 版本

## 主要功能

- 默认不改写官方 Codex 共享的 `~/.codex/auth.json`
- 停用周期 OAuth token 轮换，保留只读用量查询
- 本地 session token 与成本估算
- 基于独立 `CODEX_HOME` 的多账号运行档案
- 可选的本地账号网关与退出自动还原
- CodexPlusPlus-Themes、DreamSkin.cc、Codex-Dream-Skin 等主题目录
- 深浅模式玻璃皮肤、壁纸注入和本地主题导入
- 全新的 codex-box 盒体命令行图标

## 安装

下载 `codex-box-1.2.8-macOS.dmg`，打开后将 `codex-box.app` 拖入 Applications。

当前安装包采用 ad-hoc 签名且未做 Apple 公证。首次启动若被 Gatekeeper 阻止，
请在“系统设置 → 隐私与安全性”中确认允许打开。

## 完整性

DMG SHA-256：

```text
ad234603b8d3423db2f6d027beb2d32850dd0a3944a9c33a7d9a832bd3393703
```

## 开源与署名

项目使用 MIT License。上游关系和主题生态许可边界见
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)。
