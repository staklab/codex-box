import AppKit
import Combine
import Foundation

/// 壁纸/皮肤注入服务（CDP）。
///
/// ⚠️ 安全边界，改动前务必读完：
/// 本服务需要以 `--remote-debugging-port` 启动 Codex 桌面版，并通过 Chrome DevTools Protocol
/// 往渲染进程注入 CSS。这会在 127.0.0.1 上开一个调试端口，**任何本地进程都能连上去
/// 完全控制该应用窗口**（读取页面内容、执行任意 JS）。这是壁纸功能的固有代价，
/// 换个 App 实现也一样——风险来自注入本身，不来自谁实现它。
///
/// 因此本服务的设计原则：
/// 1. 默认关闭，只有用户显式开启才启动带调试端口的实例；
/// 2. 端口绑定 127.0.0.1，且随机化，不用固定的 9229；
/// 3. 只注入样式，不注入任何会回传数据的脚本；
/// 4. 配色/字体走 `CodexThemeService` 的原生 config.toml 路径，不依赖本服务。
///    即使从不开启注入，主题的颜色部分依然生效。
@MainActor
final class CodexSkinInjectionService: ObservableObject {
    static let shared = CodexSkinInjectionService()

    enum Status: Equatable {
        case idle
        case launching
        case connected(port: Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    /// 深色模式下主表面（对话区、卡片）的不透明度。
    static let darkSurfaceAlpha = 0.55

    /// 深色模式下次级面板（侧栏、输入框底）的不透明度。
    static let darkPanelAlpha = 0.45

    /// 浅色模式的大面积容器保持透明，这组低 alpha 仅承托卡片、选中项等局部表面。
    static let lightSurfaceAlpha = 0.14
    static let lightPanelAlpha = 0.10

    /// `#rrggbb` → `rgba(r, g, b, a)`。支持 3/6/8 位十六进制。
    static func rgbaString(from value: String?, alpha: Double) -> String? {
        guard let normalized = CodexThemeService.normalizedHex(value) else { return nil }
        var hex = normalized.dropFirst()
        if hex.count == 3 {
            hex = Substring(hex.map { "\($0)\($0)" }.joined())
        }
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return nil }
        let red = (value >> 16) & 0xFF
        let green = (value >> 8) & 0xFF
        let blue = value & 0xFF
        return "rgba(\(red), \(green), \(blue), \(alpha))"
    }

    private let session: URLSession
    private var debugPort: Int?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 启动

    /// 以调试端口启动 Codex 桌面版。已在运行的实例注入不进去，必须由本方法启动。
    func launchCodexWithDebugging() async throws -> Int {
        self.status = .launching

        let port = Int.random(in: 49_152...65_535)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? Self.fallbackAppURL() else {
            self.status = .failed("找不到 Codex 桌面版")
            throw CodexThemeError.configMissing
        }

        // 已在运行的实例必须先退出：macOS 对运行中的应用只会激活，不会应用新的启动参数，
        // 调试端口也就不会打开。
        try await self.terminateRunningCodex()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.arguments = ["--remote-debugging-port=\(port)"]

        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        self.debugPort = port

        // 等待调试端口就绪
        for _ in 0..<40 {
            if (try? await self.pageTargets(port: port))?.isEmpty == false {
                self.status = .connected(port: port)
                return port
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        self.status = .failed("调试端口未就绪（应用可能禁用了远程调试）")
        throw CodexThemeError.downloadFailed("remote debugging port \(port) not ready")
    }

    /// 请求正在运行的 Codex 正常退出，并等待其真正结束。
    /// 用 `terminate()` 而非 `forceTerminate()`，让应用有机会保存状态。
    private func terminateRunningCodex() async throws {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.openai.codex" }
        guard running.isEmpty == false else { return }

        for application in running { application.terminate() }

        for _ in 0..<40 {
            let stillRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == "com.openai.codex" }
            if stillRunning == false { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func fallbackAppURL() -> URL? {
        let candidate = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - CDP 目标发现

    struct CDPTarget: Decodable {
        let id: String
        let type: String
        let title: String
        let url: String
        let webSocketDebuggerUrl: String?
    }

    /// 当前是否已有可注入的调试目标。
    /// 用来判断一个刚启动的 Codex 是不是由 codex-box 拉起的——
    /// 是的话就不必再接管重启。
    func hasLiveDebugTarget() async -> Bool {
        guard let port = self.debugPort else { return false }
        let targets = try? await self.pageTargets(port: port)
        return targets?.isEmpty == false
    }

    func pageTargets(port: Int) async throws -> [CDPTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        // 调试端口是本机回环，必须绕过系统代理，否则会被代理拦截
        request.networkServiceType = .responsiveData

        let (data, _) = try await self.session.data(for: request)
        let targets = try JSONDecoder().decode([CDPTarget].self, from: data)
        return targets.filter { $0.type == "page" && $0.webSocketDebuggerUrl != nil }
    }

    // MARK: - 注入

    /// 把主题的壁纸与 CSS 注入到所有页面目标。
    func injectSkin(themeID: String, themeService: CodexThemeService) async throws {
        guard let port = self.debugPort else {
            throw CodexThemeError.downloadFailed("尚未以调试端口启动 Codex")
        }
        let definition = try themeService.loadDefinition(id: themeID)
        let css = try self.buildCSS(themeID: themeID, definition: definition, themeService: themeService)

        let targets = try await self.pageTargets(port: port)
        for target in targets {
            guard let wsURL = target.webSocketDebuggerUrl.flatMap(URL.init(string:)) else { continue }
            try await self.evaluate(javascript: Self.installerJS(css: css), webSocketURL: wsURL)
        }
    }

    /// 移除注入的样式（不需要重启应用）。
    func removeSkin() async throws {
        guard let port = self.debugPort else { return }
        let targets = try await self.pageTargets(port: port)
        let js = """
        (() => { const el = document.getElementById('codexbar-skin'); if (el) el.remove(); return 'removed'; })()
        """
        for target in targets {
            guard let wsURL = target.webSocketDebuggerUrl.flatMap(URL.init(string:)) else { continue }
            try await self.evaluate(javascript: js, webSocketURL: wsURL)
        }
    }

    private func buildCSS(
        themeID: String,
        definition: CodexThemeDefinition,
        themeService: CodexThemeService
    ) throws -> String {
        let colors = definition.colors
        var rules: [String] = []

        // 覆盖 Codex 真正用来渲染界面的 CSS 变量。
        //
        // 重要教训：`config.toml` 里的 `[desktop.appearance*ChromeTheme]` **不驱动界面配色**。
        // 实测把 surface 写成 #ff0000 重启后，界面仍是默认的 #181818；
        // 那张表只有 `opaqueWindows` 之类的窗口属性会生效。
        // 界面配色来自下面这组变量，只能通过注入覆盖。
        // 遮罩取自**应用自身的明暗模式**，而不是主题的明暗。
        //
        // 这是反复试错换来的结论：早先用主题背景色去覆盖 surface 和文字色，
        // 浅色主题（背景 #f1f7f3、文字 #24332e）套在深色模式的 Codex 上，
        // 会与应用自己的「浅色文字」配对方式打架——要么首页卡片变成实心白块，
        // 要么正文糊得读不清。壁纸才是主题的视觉主体，配色只负责点缀。
        //
        // 因此：遮罩按模式给中性色（保证对比度），主题色只用于强调与 diff。
        var accents: [String] = []
        func put(_ name: String, _ value: String?) {
            guard let hex = CodexThemeService.normalizedHex(value) else { return }
            accents.append("  \(name): \(hex) !important;")
        }
        put("--wb-focus", colors.accent)
        put("--diffs-addition-color-override", colors.secondary)
        put("--diffs-deletion-color-override", colors.highlight)

        rules.append("""
        .electron-dark {
          --cb-scrim: rgba(24, 24, 24, \(Self.darkSurfaceAlpha));
          --cb-scrim-2: rgba(20, 20, 20, \(Self.darkPanelAlpha));
        }
        .electron-light {
          --cb-scrim: rgba(245, 245, 247, \(Self.lightSurfaceAlpha));
          --cb-scrim-2: rgba(240, 240, 242, \(Self.lightPanelAlpha));
        }
        :root, .electron-dark, .electron-light {
          --wb-surface-primary: var(--cb-scrim) !important;
          --color-background-surface: var(--cb-scrim) !important;
          --wb-surface-secondary: var(--cb-scrim-2) !important;
          --color-background-surface-under: var(--cb-scrim-2) !important;
        \(accents.joined(separator: "\n"))
        }

        /* 大面积容器在深浅模式下都保持透明。aside 自带 70% 模式底色，main 又从
           侧栏边界开始而实际内容晚 16px 起步；分别着色会形成左上色块和竖向分隔带。 */
        .electron-light aside.app-shell-left-panel,
        .electron-dark aside.app-shell-left-panel,
        .electron-light main.bg-surface,
        .electron-dark main.bg-surface,
        .electron-light main[class*="_MainContentSurface_"],
        .electron-dark main[class*="_MainContentSurface_"],
        .electron-light header.h-toolbar,
        .electron-dark header.h-toolbar,
        .electron-light header[class*="h-toolbar"],
        .electron-dark header[class*="h-toolbar"] {
          background: transparent !important;
          border-color: transparent !important;
          -webkit-backdrop-filter: none !important;
          backdrop-filter: none !important;
        }

        /* 输入框的硬编码背景、16px 模糊和多层阴影都在 _ComposerLayoutRoot_*，
           Body 本身已透明。类名带构建哈希，因此统一用子串匹配。 */
        [class*="_ComposerLayoutRoot_"],
        [class*="_ComposerLayoutBody_"],
        [class*="_ComposerLayoutBody_"]::before,
        [class*="_ComposerLayoutBody_"]::after {
          background: transparent !important;
          -webkit-backdrop-filter: none !important;
          backdrop-filter: none !important;
        }

        [class*="_ComposerLayoutRoot_"] {
          box-shadow: 0 0 0 0.5px var(--wb-border) !important;
        }

        .electron-light [class*="_ComposerLayoutRoot_"] {
          background: rgba(248, 250, 249, 0.28) !important;
          -webkit-backdrop-filter: blur(10px) saturate(0.90) !important;
          backdrop-filter: blur(10px) saturate(0.90) !important;
          box-shadow: 0 0 0 0.5px var(--wb-border),
                      0 4px 18px rgba(36, 51, 46, 0.08) !important;
        }

        .electron-dark [class*="_ComposerLayoutRoot_"] {
          background: rgba(18, 20, 20, 0.16) !important;
          -webkit-backdrop-filter: blur(6px) saturate(0.90) !important;
          backdrop-filter: blur(6px) saturate(0.90) !important;
          box-shadow: 0 0 0 0.5px var(--wb-border),
                      0 3px 14px rgba(0, 0, 0, 0.10) !important;
        }

        /* 新对话首页会给 composer root 追加 gap-2，并把根圆角重置为 0；
           Body 还会额外叠四层阴影。统一回已有对话的圆角玻璃样式。 */
        [class*="_ComposerLayoutRoot_"].gap-2 {
          border-radius: 25px !important;
          overflow: hidden !important;
        }

        [class*="_ComposerLayoutRoot_"].gap-2 [class*="_ComposerLayoutBody_"] {
          box-shadow: none !important;
        }

        .electron-light aside.app-shell-left-panel {
          background: rgba(248, 250, 249, 0.18) !important;
        }

        /* aside::after 会继承同色背景并向 resize handle 右侧延伸，形成越界蒙版。 */
        .electron-light aside.app-shell-left-panel::after {
          content: none !important;
          background: transparent !important;
        }

        /* 模式调节直接作用于壁纸层，避免独立蒙层与 Electron 标题栏分层合成。 */
        .electron-light body::before {
          filter: contrast(0.82) saturate(0.90);
        }

        .electron-dark body::before {
          filter: brightness(0.55) saturate(0.90);
        }

        body::after {
          content: none !important;
        }

        /* Codex 在主内容 y=46 下方叠一层 16px surface 渐变；浅色呈白条，
           深色呈黑灰条。两种模式都直接移除。 */
        [class*="_MainContentTopFade_"] {
          display: none !important;
          background: none !important;
        }

        """)

        // 壁纸：以 data URI 内联，避免再开一个本地 HTTP 服务扩大暴露面
        let directory = themeService.themeDirectory(id: themeID)
        let imageCandidates = ["image.png", "image.jpg", "image.jpeg", "image.webp"]
        if let imageURL = imageCandidates
            .map({ directory.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let imageData = try? Data(contentsOf: imageURL) {
            let mime = imageURL.pathExtension == "png" ? "image/png"
                : (imageURL.pathExtension == "webp" ? "image/webp" : "image/jpeg")
            let base64 = imageData.base64EncodedString()

            // Codex 的界面由两层不透明的 <main> 铺满：
            //   外层 main.bg-surface            —— 整窗
            //   内层 main[class*=_MainContentSurface_] —— 右侧对话区
            // 两者都是 rgb(24,24,24) 实色，壁纸垫在它们底下是看不见的，
            // 必须把它们降成半透明。内层的类名带构建哈希（如 _MainContentSurface_1k2yc_2），
            // 所以用子串选择器匹配，避免 Codex 升级后失效。
            // 只铺壁纸。表面的透明度交给上面那组 `--wb-*` 变量统一管理——
            // 早先这里还硬编码了 `rgba(24,24,24,0.55)` 和 `backdrop-filter`，
            // 在浅色主题下会与变量打架，并在窗口顶端留下一条发亮的窄带。
            rules.append("""
            html, body { background: transparent !important; }

            body::before {
              content: '';
              position: fixed;
              inset: 0;
              z-index: 0;
              pointer-events: none;
              background-image: url("data:\(mime);base64,\(base64)");
              background-size: cover;
              background-position: center;
            }
            """)
        }

        var variables: [String] = []
        if let background = CodexThemeService.normalizedHex(colors.background) {
            variables.append("--codexbar-bg: \(background);")
        }
        if let accent = CodexThemeService.normalizedHex(colors.accent) {
            variables.append("--codexbar-accent: \(accent);")
        }
        if let text = CodexThemeService.normalizedHex(colors.text) {
            variables.append("--codexbar-text: \(text);")
        }
        if variables.isEmpty == false {
            rules.append(":root {\n  " + variables.joined(separator: "\n  ") + "\n}")
        }

        return rules.joined(separator: "\n\n")
    }

    private static func installerJS(css: String) -> String {
        let encoded = Data(css.utf8).base64EncodedString()
        return """
        (() => {
          const css = atob('\(encoded)');
          let el = document.getElementById('codexbar-skin');
          if (!el) {
            el = document.createElement('style');
            el.id = 'codexbar-skin';
            document.documentElement.appendChild(el);
          }
          el.textContent = css;
          return 'ok';
        })()
        """
    }

    // MARK: - 最小 CDP 客户端

    /// 通过 WebSocket 发一条 `Runtime.evaluate`。只发不收业务数据，收到首个响应即断开。
    private func evaluate(javascript: String, webSocketURL: URL) async throws {
        let task = self.session.webSocketTask(with: webSocketURL)
        // 壁纸以 data URI 内联，一张 3MB 的图转 base64 后约 4MB，
        // 而 maximumMessageSize 默认只有 1MiB，不放宽的话整条消息会被直接丢弃。
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let payload: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": javascript,
                "awaitPromise": false,
                "returnByValue": true,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }

        try await task.send(.string(text))
        _ = try? await task.receive()
    }
}
