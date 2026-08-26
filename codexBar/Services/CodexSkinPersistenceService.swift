import AppKit
import Combine
import Foundation
import ServiceManagement

/// 开机自启 + 主题持久化 + 自动接管 Codex 启动。
///
/// 背景：Codex 的界面配色改不了配置文件，只能注入（实测把 config.toml 的
/// surface 写成 #ff0000 界面仍是默认 #181818）。而注入需要 Codex 以调试端口启动，
/// 所以"皮肤一直在"这件事只能靠 codex-box 在你打开 Codex 时接管一次启动。
@MainActor
final class CodexSkinPersistenceService: ObservableObject {
    static let shared = CodexSkinPersistenceService()

    private enum Key {
        static let autoReapply = "codexbar.skin.autoReapply"
        static let takeOverLaunch = "codexbar.skin.takeOverLaunch"
    }

    /// codex-box 启动时自动把上次的主题重新注入
    @Published var autoReapplyOnStart: Bool {
        didSet { UserDefaults.standard.set(self.autoReapplyOnStart, forKey: Key.autoReapply) }
    }

    /// 侦测到 Codex 被直接打开（没有调试端口）时，接管重启并注入
    @Published var takeOverCodexLaunch: Bool {
        didSet {
            UserDefaults.standard.set(self.takeOverCodexLaunch, forKey: Key.takeOverLaunch)
            self.updateLaunchObserver()
        }
    }

    /// 开机自启（登录项）
    @Published private(set) var launchAtLogin: Bool = false

    private var launchObserver: NSObjectProtocol?
    private var isTakingOver = false

    init() {
        let defaults = UserDefaults.standard
        self.autoReapplyOnStart = defaults.object(forKey: Key.autoReapply) as? Bool ?? true
        self.takeOverCodexLaunch = defaults.object(forKey: Key.takeOverLaunch) as? Bool ?? false
        self.launchAtLogin = Self.readLaunchAtLogin()
        self.updateLaunchObserver()
    }

    // MARK: - 开机自启

    private static func readLaunchAtLogin() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        self.launchAtLogin = Self.readLaunchAtLogin()
    }

    // MARK: - 启动时重新应用

    /// codexbar 启动后调用。上次应用过主题就重新注入一次。
    func reapplyIfNeeded(
        themeService: CodexThemeService,
        injection: CodexSkinInjectionService
    ) async {
        guard self.autoReapplyOnStart,
              let themeID = themeService.state.appliedThemeID,
              themeService.installedTheme(id: themeID) != nil
        else { return }

        // Codex 没在跑就不打扰；等它被打开时由接管逻辑处理
        guard NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.openai.codex" }) else { return }

        try? await self.applyNow(themeID: themeID, themeService: themeService, injection: injection)
    }

    // MARK: - 接管 Codex 启动

    private func updateLaunchObserver() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        guard self.takeOverCodexLaunch else { return }

        self.launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                application.bundleIdentifier == "com.openai.codex" else { return }
            Task { @MainActor in
                await self?.handleCodexLaunched()
            }
        }
    }

    /// Codex 被直接打开时：若它没有调试端口（也就没法注入），就接管重启一次。
    private func handleCodexLaunched() async {
        guard self.isTakingOver == false else { return }
        let themeService = CodexThemeService.shared
        guard let themeID = themeService.state.appliedThemeID,
              themeService.installedTheme(id: themeID) != nil else { return }

        self.isTakingOver = true
        defer { self.isTakingOver = false }

        // 给它一点时间起来；已有调试端口说明本来就是 codex-box 启动的，不必接管
        try? await Task.sleep(for: .seconds(2))
        if await CodexSkinInjectionService.shared.hasLiveDebugTarget() { return }

        try? await self.applyNow(
            themeID: themeID,
            themeService: themeService,
            injection: CodexSkinInjectionService.shared
        )
    }

    private func applyNow(
        themeID: String,
        themeService: CodexThemeService,
        injection: CodexSkinInjectionService
    ) async throws {
        _ = try await injection.launchCodexWithDebugging()
        try await injection.injectSkin(themeID: themeID, themeService: themeService)
    }
}
