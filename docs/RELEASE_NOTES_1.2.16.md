# codex-box 1.2.16

修复 Codex Desktop 更新到 26.908.40834 后，主题壁纸仅在左侧显示、右侧被实色背景遮挡的问题。

- 兼容新版 `data-theme` 与旧版 `electron-light` / `electron-dark` 外观标记，恢复右侧主区的主题壁纸。
- 深浅模式沿用原有配色、壁纸亮度与透明度，支持运行中切换外观。
- 增加新旧外观标记、主区背景、连续明暗切换、重复换肤、点击与恢复的回归检查。

验证：皮肤回归检查、macOS Release 构建与签名校验通过；新版 Codex 页面计算样式确认右侧两层主容器恢复原有透明度。

## 下载

- macOS：`codex-box-1.2.16-macOS.dmg`，Apple Silicon / Intel 通用安装包。
- Windows：[1.2.15 安装包](https://github.com/staklab/codex-box/releases/tag/v1.2.15)。
