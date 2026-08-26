import AppKit
import Combine
import Foundation
import Network

/// 预览页的本地 HTTP 服务。
///
/// 为什么不用 `file://` + `codexbar://` 自定义 scheme：
/// 浏览器（尤其 Chrome）会拦截由 `file://` 页面发起的自定义 scheme 跳转，
/// 表现就是"点了没反应"。改成本地 HTTP 后页面与接口同源，
/// `fetch()` 直接可用，还能把执行结果回显到页面上。
///
/// 安全上：只绑定 127.0.0.1、端口随机、仅接受三个只读/受控接口，
/// 且 `apply` 的主题 id 必须存在于「已安装」或「当前市场列表」中。
@MainActor
final class CodexPreviewServer: ObservableObject {
    static let shared = CodexPreviewServer()

    @Published private(set) var port: UInt16?

    private var listener: NWListener?
    /// 每次请求 `/` 都重新生成页面，这样在页面里装完主题后刷新即可看到「已安装」同步更新。
    private var htmlProvider: (() async -> String)?
    private weak var themeService: CodexThemeService?

    /// 启动服务（若已启动则复用），登记页面生成器并返回访问地址。
    func serve(htmlProvider: @escaping () async -> String, themeService: CodexThemeService) throws -> URL {
        self.htmlProvider = htmlProvider
        self.themeService = themeService

        if let port = self.port, self.listener != nil {
            return URL(string: "http://127.0.0.1:\(port)/")!
        }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor in
                self?.receive(on: connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor in
                self?.port = listener.port?.rawValue
            }
        }
        listener.start(queue: .main)
        self.listener = listener

        // 等端口分配完成
        for _ in 0..<50 {
            if let port = listener.port?.rawValue {
                self.port = port
                return URL(string: "http://127.0.0.1:\(port)/")!
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw CodexThemeError.downloadFailed("预览服务启动失败")
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
        self.port = nil
    }

    // MARK: - 极简 HTTP

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self, let data, data.isEmpty == false else {
                if isComplete { connection.cancel() }
                return
            }
            let request = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                await self.route(request: request, on: connection)
            }
        }
    }

    private func route(request: String, on connection: NWConnection) async {
        guard let requestLine = request.split(separator: "\r\n").first else {
            self.respond(connection, status: "400 Bad Request", body: "bad request")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            self.respond(connection, status: "400 Bad Request", body: "bad request")
            return
        }
        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? "/"

        switch path {
        case "/":
            let body = await self.htmlProvider?() ?? "<h1>页面未就绪</h1>"
            self.respond(connection, status: "200 OK", body: body, contentType: "text/html; charset=utf-8")
        case "/apply":
            let result = await self.handleApply(target: target)
            self.respond(connection, status: "200 OK", body: result, contentType: "application/json; charset=utf-8")
        case "/restart-codex":
            let result = await self.handleRestartCodex()
            self.respond(connection, status: "200 OK", body: result, contentType: "application/json; charset=utf-8")
        default:
            self.respond(connection, status: "404 Not Found", body: "not found")
        }
    }

    private func queryItems(from target: String) -> [String: String] {
        guard let query = target.split(separator: "?").dropFirst().first else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            result[String(key)] = value.removingPercentEncoding ?? value
        }
        return result
    }

    private func handleApply(target: String) async -> String {
        guard let themeService = self.themeService else {
            return #"{"ok":false,"message":"服务未就绪"}"#
        }
        let items = self.queryItems(from: target)
        guard let themeID = items["id"], themeID.isEmpty == false else {
            return #"{"ok":false,"message":"缺少主题 id"}"#
        }
        let wantsWallpaper = items["wallpaper"] == "1"

        do {
            if themeService.installedTheme(id: themeID) == nil {
                guard let listing = themeService.listings.first(where: { $0.id == themeID }) else {
                    return #"{"ok":false,"message":"市场列表里没有这个主题，请先刷新"}"#
                }
                _ = try await themeService.install(listing)
            }

            try themeService.applyNativeColors(themeID: themeID)

            // 界面配色只能靠注入：config.toml 的主题表不驱动界面（实测 #ff0000 无效）。
            // 因此无论用户点的是「应用配色」还是「应用+壁纸」，都要走注入。
            let injection = CodexSkinInjectionService.shared
            _ = try await injection.launchCodexWithDebugging()
            try await injection.injectSkin(themeID: themeID, themeService: themeService)
            return #"{"ok":true,"message":"已应用（Codex 已重启并注入）","restarted":true}"#
        } catch {
            let message = error.localizedDescription
                .replacingOccurrences(of: "\"", with: "'")
            return "{\"ok\":false,\"message\":\"\(message)\"}"
        }
    }

    /// 普通重启 Codex（不带调试端口，也就没有壁纸注入）。
    private func handleRestartCodex() async -> String {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.openai.codex" }
        for application in running { application.terminate() }

        for _ in 0..<40 {
            let stillRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == "com.openai.codex" }
            if stillRunning == false { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? (FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app")
                ? URL(fileURLWithPath: "/Applications/ChatGPT.app") : nil) else {
            return #"{"ok":false,"message":"找不到 Codex 桌面版"}"#
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return #"{"ok":true,"message":"Codex 已重启"}"#
        } catch {
            return #"{"ok":false,"message":"重启失败"}"#
        }
    }

    private func respond(
        _ connection: NWConnection,
        status: String,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
