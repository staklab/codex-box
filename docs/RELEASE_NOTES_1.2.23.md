# codex-box 1.2.23

更新 GPT-6.1 Sol、GPT-6 Sol 和 GPT-6 Luna 的模型选项与官方 API 费用估算，并修复 macOS 设置中的记录页持续加载问题。

- macOS 与 Windows 同步支持三个模型的普通、Fast、缓存读取、缓存写入及长上下文费率，兼容日志中的 `fast` 和 `priority`。
- 单次输入超过 272,000 tokens 时，按官方规则调整整个请求的费用，并与 Fast 倍率叠加；详细价格和官方来源见 [定价说明](https://github.com/staklab/codex-box/blob/v1.2.23/docs/GPT6_SOL_LUNA_PRICING.md)。
- macOS 记录页打开后先显示缓存中的会话与模型记录，再后台更新，避免等待大量会话日志扫描。
- 初次加载与全量刷新都有有效的 15 秒超时；超时后保留已有记录并恢复操作，同时取消对应扫描。

## 下载

- macOS：`codex-box-1.2.23-macOS.dmg`，Apple Silicon / Intel 通用安装包。
- Windows x64：EXE、中文 MSI 和英文 MSI，通常选择 EXE 即可。

## 验证

macOS 已通过模型费用、记录快照与页面状态回归测试，包括不响应取消的底层任务仍能及时超时，以及启动后直接显示持久缓存；本机安装效果已由用户确认。Windows 发布工作流执行前端与 Rust 测试、换肤及进程隔离、官方客户端验证、安装包构建和启动检查。
