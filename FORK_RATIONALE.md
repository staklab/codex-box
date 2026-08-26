# 为什么有 codex-box：改造缘由与技术说明

本项目基于 MIT 协议的 [lizhelang/codexbar](https://github.com/lizhelang/codexbar) 二次开发。
上游本身也声明"复用并改编自 xmasdong/codexbar 与 steipete/CodexBar 的 MIT 代码"，
本项目延续同样的做法：保留原始版权与许可声明，在其上继续改造。

---

## 起因：一次真实的凭据互踢事故

改造的直接起因不是"想加功能"，而是一次实际故障。

同一台 Mac 上，Codex 桌面版与 codexbar 共用 `~/.codex/auth.json`。
OpenAI 的 refresh token 是**一次性轮换**的：任何一方刷新成功，另一方手里的那枚立刻作废。
表现出来就是 Codex 反复掉登录，日志里是：

```
codex_login::auth::manager | Failed to refresh token: 401 Unauthorized
{ "code": "refresh_token_invalidated" }
```

排查过程中确认了三件事：

1. `OpenAIOAuthRefreshService` 每 5 分钟对**所有账号**强制刷新并轮换 token；
2. `CodexSyncService.synchronize()` 会把选中账号的凭据整份写进共享的 `~/.codex/auth.json`；
3. codexbar 使用的 OAuth `client_id` 与官方 Codex 桌面版**完全相同**
   （`app_EMoamEEZ73f0CkXaXp7hrann`，回调端口也同为 1455），
   因此在服务端看来它就是官方客户端本身，登录与刷新都落进同一个会话池。

这不是 bug，是设计取向的差异：上游把"切换账号"实现为改写共享凭据文件。
本项目认为在与官方客户端共存的场景下，这个取向不可行。

## 改造方向

### 一、不再改写共享凭据

- 停用 `oauthRefresh` 的周期性轮换循环
- 给 `CodexSyncService` 加总闸 `codexHomeWritesEnabled = false`，
  不再写 `~/.codex/auth.json`
- 用量轮询保留，但把它的 401 兜底（会 `refreshNow(force: true)`）换成 `.skipped`——
  查询用量本身是只读的 `GET /wham/usage`，不该牵连凭据轮换

### 二、用隔离与网关替代文件切换

- **运行档案**：每个账号一个独立 `CODEX_HOME`，各持有自己的 `auth.json`，
  结构上不可能互相干扰。多账号可并行跑不同项目。
  （GUI 多实例走不通——`ChatGPT.app` 在 prod 构建下强制 `requestSingleInstanceLock`，
  `open -n`、直接 exec、`NSWorkspace` 带环境变量三种方式实测均被接管退出；
  CLI 则完全尊重 `CODEX_HOME`。）
- **账号网关**：Codex → `127.0.0.1:1456` → `chatgpt.com/backend-api/codex/responses`，
  网关按请求注入 Bearer，凭据只存在于请求头，`auth.json` 全程不动。
  配置写入是外科式的，只动 `model_provider` 与 `[model_providers.*]`，
  且 codex-box 退出时自动还原为官方直连。

### 三、皮肤：接入市场并修正实现路径

皮肤方向受到 [CodexPlusPlus](https://github.com/BigPizzaV3/CodexPlusPlus)
产品设计的启发，并兼容 MIT 许可的
[CodexPlusPlus-Themes](https://github.com/BigPizzaV3/CodexPlusPlus-Themes) 清单格式与
[Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin) 主题生态。
CodexPlusPlus 主仓库采用 AGPL-3.0；本项目没有复制或改编其中的 Rust / TypeScript
源码或素材，CDP 客户端、主题安装和注入逻辑均为 Swift 独立实现。

一个必须写下来的实测结论：

> **`config.toml` 里的 `[desktop.appearance*ChromeTheme]` 不驱动 Codex 的界面配色。**
> 把 `surface` 写成 `#ff0000` 重启后，界面仍是默认的 `#181818`。
> 该表只有 `opaqueWindows` 之类的窗口属性会生效
> （可通过 `documentElement.className` 上 `electron-opaque` 的出现与消失验证）。

真正决定界面的是这组 CSS 变量，只能通过 CDP 注入覆盖：

```
--wb-surface-primary / --wb-surface-secondary
--color-background-surface / --color-background-surface-under
--wb-text-primary / --wb-text-tertiary
--wb-border / --wb-divider / --wb-focus
--diffs-addition-color-override / --diffs-deletion-color-override
```

另一条同样重要的经验：**surface 类变量必须带 alpha**。
直接写主题原色会让浅色主题（如背景 `#f1f7f3`）把首页建议卡片渲染成实心白块，
壁纸完全被盖住——那些卡片直接继承 `--wb-surface-primary`。

皮肤市场支持三种目录格式：

| 库 | 格式 | 完整性校验 |
| --- | --- | --- |
| DreamSkin.cc | 分页 REST，配色内嵌于 `displayMeta` | 包带 `packageSha256` |
| CodexPlusPlus-Themes | `themes[]` + 相对路径 | 无，采用 TOFU 钉住 |
| Awesome Codex Skins | `skins[]` + `.codexskin` zip | 上游提供 sha256，强校验 |

## 安全取向

改造中始终坚持的几条：

- **注入的代价如实告知**：开启调试端口期间，本机任何进程都能控制该窗口。
  因此默认关闭、端口随机化（不用固定的 9229）、只注入样式不注入回传脚本。
- **网关的代价如实告知**：启用期间 Codex 的可用性依赖 codexbar 在运行，
  故提供退出自动还原与紧急还原两道保险。
- **配置写入一律合并式**：只覆盖目标键，其余逐字节保留。
  早先的整表替换会静默吃掉用户自己设的 `contrast`，这类"悄悄改坏"的行为不可接受。
- 移除了上游仓库中的 `register/codex.csv`——那是 64 行明文邮箱与口令，
  不参与编译，但没有理由留在硬盘上。

## 与上游的关系

改造是取向差异，不是对上游的否定。上游面向"用 codexbar 管理多账号"的场景，
本项目面向"与官方 Codex 桌面版长期共存"的场景，两者的约束不同。

其中"不再改写共享 `auth.json`"这一条对上游可能有普遍价值，
适合以 PR 形式回馈（例如把凭据写入做成可关闭的开关，而非默认行为）。
其余改动（皮肤市场、运行档案、网关）耦合较深，更适合作为独立项目存在。

## 许可

MIT。上游版权声明与许可文本完整保留于 `LICENSE`，
署名链条及主题生态的许可证边界记录于 `THIRD_PARTY_NOTICES.md`。
