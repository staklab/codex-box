import AppKit
import Foundation
import SwiftUI

@MainActor
protocol OpenAILoginOAuthManaging: AnyObject {
    var pendingAuthURL: String? { get }
    func startOAuth(
        openBrowser: Bool,
        activate: Bool,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    )
    func startRemoteConnectionOAuth(
        openBrowser: Bool,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    )
    func completeOAuth(from input: String)
    func cancel()
}

protocol LocalhostOAuthCallbackServing: AnyObject {
    func start() throws
    func stop()
}

extension OAuthManager: OpenAILoginOAuthManaging {}
extension LocalhostOAuthCallbackServer: LocalhostOAuthCallbackServing {}

extension Notification.Name {
    static let openAILoginDidSucceed = Notification.Name("lzl.codexbar.openai-login.did-succeed")
    static let openAILoginDidFail = Notification.Name("lzl.codexbar.openai-login.did-fail")
}

private struct OpenAILoginWindowView: View {
    @ObservedObject private var oauth = OAuthManager.shared

    var body: some View {
        OpenAIManualOAuthSheet(
            authURL: oauth.pendingAuthURL ?? "",
            isAuthenticating: oauth.isAuthenticating,
            errorMessage: oauth.errorMessage,
            callbackInput: Binding(
                get: { oauth.callbackInput },
                set: { oauth.callbackInput = $0 }
            )
        ) { input in
            oauth.completeOAuth(from: input)
        } onOpenBrowser: {
            guard let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) else { return }
            NSWorkspace.shared.open(url)
        } onCopyLink: {
            guard let authURL = oauth.pendingAuthURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(authURL, forType: .string)
        } onCancel: {
            OpenAILoginCoordinator.shared.cancel()
        }
    }
}

@MainActor
final class OpenAILoginCoordinator {
    static let shared = OpenAILoginCoordinator()

    static let windowID = "oauth-login"
    static let loginURLScheme = "com.codexbox.oauth"
    static let loginHost = "login"

    private let oauth: any OpenAILoginOAuthManaging
    private let callbackServerFactory: (@escaping @MainActor (String) -> Void) -> any LocalhostOAuthCallbackServing
    private let openWindowAction: () -> Void
    private let closeWindowAction: () -> Void
    private let openURLAction: (URL) -> Void

    private var callbackServer: (any LocalhostOAuthCallbackServing)?
    private var remoteConnectionSuccessHandler: ((TokenAccount) -> Void)?

    init(
        oauth: (any OpenAILoginOAuthManaging)? = nil,
        callbackServerFactory: ((@escaping @MainActor (String) -> Void) -> any LocalhostOAuthCallbackServing)? = nil,
        openWindowAction: (() -> Void)? = nil,
        closeWindowAction: (() -> Void)? = nil,
        openURLAction: ((URL) -> Void)? = nil
    ) {
        self.oauth = oauth ?? OAuthManager.shared
        self.callbackServerFactory = callbackServerFactory ?? {
            LocalhostOAuthCallbackServer(onCallback: $0)
        }
        self.openWindowAction = openWindowAction ?? Self.defaultOpenWindow
        self.closeWindowAction = closeWindowAction ?? Self.defaultCloseWindow
        self.openURLAction = openURLAction ?? { NSWorkspace.shared.open($0) }
    }

    func start() {
        self.remoteConnectionSuccessHandler = nil
        oauth.startOAuth(openBrowser: false, activate: false) { result in
            self.stopCallbackServer()
            switch result {
            case .success(let completion):
                let store = TokenStore.shared
                store.load()
                Task {
                    await WhamService.shared.refreshOne(account: completion.account, store: store)
                }
                self.closeWindowAction()
                NotificationCenter.default.post(
                    name: .openAILoginDidSucceed,
                    object: nil,
                    userInfo: [
                        "active": completion.active,
                        "message": completion.active
                            ? "Updated Codex configuration. Changes apply to new sessions."
                            : "Saved OpenAI account.",
                    ]
                )
            case .failure(let error):
                NotificationCenter.default.post(
                    name: .openAILoginDidFail,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }

        self.startCallbackServer()
        self.openWindowAction()
        if let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) {
            self.openURLAction(url)
        }
    }

    func startRemoteConnectionLogin(onSuccess: ((TokenAccount) -> Void)? = nil) {
        self.remoteConnectionSuccessHandler = onSuccess
        oauth.startRemoteConnectionOAuth(openBrowser: false) { result in
            self.stopCallbackServer()
            switch result {
            case .success(let completion):
                let store = TokenStore.shared
                store.load()
                self.remoteConnectionSuccessHandler?(completion.account)
                self.remoteConnectionSuccessHandler = nil
                self.closeWindowAction()
                NotificationCenter.default.post(
                    name: .openAILoginDidSucceed,
                    object: nil,
                    userInfo: [
                        "active": false,
                        "message": "Saved remote connection account.",
                    ]
                )
            case .failure(let error):
                self.remoteConnectionSuccessHandler = nil
                NotificationCenter.default.post(
                    name: .openAILoginDidFail,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }

        self.startCallbackServer()
        self.openWindowAction()
        if let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) {
            self.openURLAction(url)
        }
    }

    func cancel() {
        self.stopCallbackServer()
        self.oauth.cancel()
        self.remoteConnectionSuccessHandler = nil
        self.closeWindowAction()
    }

    private static func defaultOpenWindow() {
        DetachedWindowPresenter.shared.show(
            id: Self.windowID,
            title: "OpenAI OAuth",
            size: CGSize(width: 560, height: 420)
        ) {
            OpenAILoginWindowView()
        }
    }

    private static func defaultCloseWindow() {
        DetachedWindowPresenter.shared.close(id: Self.windowID)
    }

    private func startCallbackServer() {
        self.stopCallbackServer()

        let server = self.callbackServerFactory { callbackURL in
            self.oauth.completeOAuth(from: callbackURL)
        }
        do {
            try server.start()
            self.callbackServer = server
        } catch {
            NSLog("codex-box localhost OAuth callback listener unavailable: %@", error.localizedDescription)
            self.callbackServer = nil
        }
    }

    private func stopCallbackServer() {
        self.callbackServer?.stop()
        self.callbackServer = nil
    }
}

enum CodexBarURLRouter {
    /// 预览页回调用的 scheme：codex-box://apply?id=xxx&wallpaper=1
    static let appURLScheme = "codexbox"

    @MainActor
    static func handle(_ url: URL) {
        if url.scheme?.caseInsensitiveCompare(Self.appURLScheme) == .orderedSame {
            self.handleAppCommand(url)
            return
        }

        guard url.scheme?.caseInsensitiveCompare(OpenAILoginCoordinator.loginURLScheme) == .orderedSame else { return }

        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        if host == OpenAILoginCoordinator.loginHost || path == "/\(OpenAILoginCoordinator.loginHost)" {
            OpenAILoginCoordinator.shared.start()
        }
    }

    /// 处理来自浏览器预览页的一键应用请求。
    ///
    /// 只接受 `apply` 这一个动作，参数只有主题 id 和是否要壁纸——
    /// 刻意保持极窄的入口，避免把一个可被任意网页触发的 scheme 变成宽泛的控制通道。
    /// 主题必须已在本地安装过，否则忽略（不会因为一个链接就去下载任意内容）。
    @MainActor
    private static func handleAppCommand(_ url: URL) {
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "apply" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        guard let themeID = items.first(where: { $0.name == "id" })?.value,
              themeID.isEmpty == false else { return }

        let wantsWallpaper = items.first(where: { $0.name == "wallpaper" })?.value == "1"
        let themeService = CodexThemeService.shared

        // 未安装的先装。安装源限定为「当前已加载的市场列表」——
        // 也就是用户自己配置过的那些库，链接里带什么 id 都不会导致从任意地址下载。
        let pendingListing = themeService.installedTheme(id: themeID) == nil
            ? themeService.listings.first(where: { $0.id == themeID })
            : nil

        if themeService.installedTheme(id: themeID) == nil, pendingListing == nil {
            NotificationCenter.default.post(
                name: .codexbarThemeApplyDidFinish,
                object: nil,
                userInfo: ["message": "市场列表里找不到这个主题，请先刷新：\(themeID)"]
            )
            return
        }

        Task { @MainActor in
            do {
                if let pendingListing {
                    _ = try await themeService.install(pendingListing)
                }
                try themeService.applyNativeColors(themeID: themeID)
                var message = "配色已应用。"

                if wantsWallpaper {
                    let injection = CodexSkinInjectionService.shared
                    _ = try await injection.launchCodexWithDebugging()
                    try await injection.injectSkin(themeID: themeID, themeService: themeService)
                    message = "配色与壁纸已应用（Codex 已重启）。"
                }

                NotificationCenter.default.post(
                    name: .codexbarThemeApplyDidFinish,
                    object: nil,
                    userInfo: ["message": message]
                )
            } catch {
                NotificationCenter.default.post(
                    name: .codexbarThemeApplyDidFinish,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }
    }
}

extension Notification.Name {
    static let codexbarThemeApplyDidFinish = Notification.Name("codexbar.theme.apply.didFinish")
}
