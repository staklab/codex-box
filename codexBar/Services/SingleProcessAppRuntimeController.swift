import Foundation

@MainActor
protocol LifecycleControlling: AnyObject {
    func start()
    func stop()
}

@MainActor
protocol OAuthRefreshLifecycleControlling: LifecycleControlling {
    func refreshDueAccountsNow() async
}

@MainActor
protocol TokenStoreReloading: AnyObject {
    func load()
}

protocol MenuHostLegacyCleaning: AnyObject {
    @discardableResult
    func cleanupLegacyArtifacts() -> MenuHostLegacyCleanupResult
}

extension MenuBarStatusItemController: LifecycleControlling {}
extension OpenAIUsagePollingService: LifecycleControlling {}
extension UpdateCoordinator: LifecycleControlling {}
extension OpenAIOAuthRefreshService: OAuthRefreshLifecycleControlling {}
extension TokenStore: TokenStoreReloading {}
extension MenuHostBootstrapService: MenuHostLegacyCleaning {}

@MainActor
final class SingleProcessAppRuntimeController {
    typealias EventRecorder = (_ type: String, _ fields: [String: Any]) -> Void

    private let statusItemHost: any LifecycleControlling
    private let usagePolling: any LifecycleControlling
    private let oauthRefresh: any OAuthRefreshLifecycleControlling
    private let updateCoordinator: any LifecycleControlling
    private let tokenStore: any TokenStoreReloading
    private let legacyMenuHostCleaner: any MenuHostLegacyCleaning
    private let recordEvent: EventRecorder

    init(
        statusItemHost: any LifecycleControlling,
        usagePolling: any LifecycleControlling,
        oauthRefresh: any OAuthRefreshLifecycleControlling,
        updateCoordinator: any LifecycleControlling,
        tokenStore: any TokenStoreReloading,
        legacyMenuHostCleaner: any MenuHostLegacyCleaning,
        recordEvent: @escaping EventRecorder
    ) {
        self.statusItemHost = statusItemHost
        self.usagePolling = usagePolling
        self.oauthRefresh = oauthRefresh
        self.updateCoordinator = updateCoordinator
        self.tokenStore = tokenStore
        self.legacyMenuHostCleaner = legacyMenuHostCleaner
        self.recordEvent = recordEvent
    }

    static func live() -> SingleProcessAppRuntimeController {
        SingleProcessAppRuntimeController(
            statusItemHost: MenuBarStatusItemController.shared,
            usagePolling: OpenAIUsagePollingService.shared,
            oauthRefresh: OpenAIOAuthRefreshService.shared,
            updateCoordinator: UpdateCoordinator.shared,
            tokenStore: TokenStore.shared,
            legacyMenuHostCleaner: MenuHostBootstrapService.shared
        ) { type, fields in
            AppLifecycleDiagnostics.shared.recordEvent(type: type, fields: fields)
        }
    }

    func start() {
        let cleanupResult = self.legacyMenuHostCleaner.cleanupLegacyArtifacts()
        if cleanupResult.hadLegacyArtifacts {
            self.recordEvent(
                "legacy_menu_host_cleaned",
                [
                    "pid": getpid(),
                    "removedAppBundle": cleanupResult.removedAppBundle,
                    "removedLease": cleanupResult.removedLease,
                    "removedRootDirectory": cleanupResult.removedRootDirectory,
                    "terminatedRunningHelper": cleanupResult.terminatedRunningHelper,
                ]
            )
        }

        self.tokenStore.load()
        self.statusItemHost.start()
        // [codexbar-safe] 用量轮询已重新启用：它只做只读的 GET wham/usage，
        // 且其 401 兜底（会强制轮换 refresh token）已在
        // OpenAIUsagePollingService 的默认 refreshAction 里关闭。
        // 这样菜单栏的剩余用量是实时准确的，同时不参与凭据轮换。
        self.usagePolling.start()

        // oauthRefresh 保持停用：它每 5 分钟对所有账号强制刷新并轮换 refresh token，
        // 与 Codex 桌面版共用 ~/.codex/auth.json 时必然互相作废，导致反复掉登录。
        // self.oauthRefresh.start()
        self.updateCoordinator.start()

        // 启动后按上次的选择恢复主题（皮肤只能靠注入，重启后不会自己回来）
        Task { @MainActor in
            await CodexSkinPersistenceService.shared.reapplyIfNeeded(
                themeService: CodexThemeService.shared,
                injection: CodexSkinInjectionService.shared
            )
        }

        self.recordEvent(
            "single_process_runtime_services_started",
            ["pid": getpid()]
        )
    }

    func stop() {
        self.updateCoordinator.stop()
        self.oauthRefresh.stop()
        self.usagePolling.stop()
        self.statusItemHost.stop()
        self.recordEvent(
            "single_process_runtime_services_stopped",
            ["pid": getpid()]
        )
    }

    func handleApplicationDidBecomeActive() async {
        self.tokenStore.load()
        await self.oauthRefresh.refreshDueAccountsNow()
    }
}
