import Combine
import Foundation

struct CodexDesktopThreadPreset: Codable, Equatable {
    var model: String
    var reasoningEffort: String
    var serviceTier: String
    var contextWindow: Int
    var updatedAt: Date
    var contextAppliedAfter: Double? = nil

    static let fallback = CodexDesktopThreadPreset(
        model: CodexBarGlobalSettings.defaultModelID,
        reasoningEffort: "medium",
        serviceTier: "flex",
        contextWindow: CodexBarGlobalSettings.defaultContextWindow,
        updatedAt: .distantPast
    )
}

private struct CodexDesktopThreadPresetFile: Codable {
    var schemaVersion: Int
    var defaultPreset: CodexDesktopThreadPreset
    var threads: [String: CodexDesktopThreadPreset]
}

/// 通过 Codex 桌面自己已经建立的 Electron -> app-server 桥接修改线程设置。
///
/// 安全边界：
/// - 不启动第二个 app-server；
/// - 不读取或写入 auth.json；
/// - 使用 `thread/read` 读取和核验，使用 `thread/settings/update` 修改下一轮设置；
/// - 首页设置只合并更新 config.toml 的四个模型键，其余内容原样保留。
@MainActor
final class CodexDesktopThreadSettingsService: ObservableObject {
    static let shared = CodexDesktopThreadSettingsService()

    enum Target: Equatable {
        case home
        case thread(String)
        case unavailable(String)
    }

    @Published private(set) var target: Target = .unavailable("尚未连接 Codex 桌面")
    @Published private(set) var preset: CodexDesktopThreadPreset = .fallback
    @Published private(set) var effectiveContextWindow: Int?
    @Published private(set) var isBusy = false
    @Published private(set) var branchProgress: String?
    private var isCreatingBranch = false
    @Published private(set) var message: String?

    private let evaluate: (String) async throws -> Any?
    private let routeScript: String?
    private let persistOverride: ((Data) throws -> Void)?
    private let readContextWindow: (String, String, Date?) async -> Int?
    private var file: CodexDesktopThreadPresetFile
    private var refreshGeneration = 0
    private var isRefreshing = false

    init(injection: CodexSkinInjectionService = .shared, evaluator: ((String) async throws -> Any?)? = nil, routeScript: String? = nil, contextReader: ((String, String, Date?) async -> Int?)? = nil, persistOverride: ((Data) throws -> Void)? = nil) {
        self.persistOverride = persistOverride
        self.readContextWindow = contextReader ?? { threadID, model, after in
            let stateDBURL = CodexPaths.stateSQLiteURL
            return await Task.detached(priority: .utility) {
                CodexThreadContextWindowReader(stateDBURL: stateDBURL)
                    .latestEffectiveContextWindow(threadID: threadID, model: model, after: after)
            }.value
        }
        self.routeScript = routeScript
        self.evaluate = evaluator ?? { script in
            try await injection.evaluateDesktop(javascript: script,
                timeout: script.contains("const timeoutMs = 60000;") ? 65 : 15)
        }
        let defaultPreset = evaluator == nil ? Self.readGlobalPreset() : .fallback
        self.file = (evaluator == nil ? Self.readFile() : nil) ?? CodexDesktopThreadPresetFile(
            schemaVersion: 1,
            defaultPreset: defaultPreset,
            threads: [:]
        )
        if self.file.defaultPreset.updatedAt == .distantPast {
            self.file.defaultPreset = defaultPreset
        }
        self.preset = self.file.defaultPreset
    }

    var targetLabel: String {
        switch self.target {
        case .home:
            return "新对话默认"
        case .thread(let id):
            return "当前对话 · \(id.prefix(8))"
        case .unavailable:
            return "会话控制未连接"
        }
    }

    /// 当前线程以 Codex 最近一次 token_count 上报的有效窗口为准；首页或尚未产生
    /// token_count 的新线程仍显示用户配置值。
    var isThread: Bool {
        if case .thread = self.target { return true }
        return false
    }

    var canEdit: Bool {
        if case .unavailable = self.target { return false }
        return !self.isBusy
    }

    static func serviceTierLabel(_ tier: String) -> String {
        switch tier {
        case "priority", "fast": return "Fast"
        case "default", "standard", "auto": return "标准"
        case "ultrafast": return "Ultra"
        case "unknown", "未提供": return "读取中"
        default: return tier
        }
    }

    var serviceTierLabel: String { Self.serviceTierLabel(self.preset.serviceTier) }

    var hasContextWindowOverride: Bool {
        guard self.file.schemaVersion >= 2, case .thread(let id) = self.target else { return false }
        return self.file.threads[id] != nil
    }

    var displayedContextWindow: Int {
        self.effectiveContextWindow ?? self.preset.contextWindow
    }

    func refresh() async {
        guard (!self.isBusy || self.isCreatingBranch), !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        self.refreshGeneration += 1
        let generation = self.refreshGeneration
        do {
            let route = try await self.currentDesktopRoute()
            guard generation == self.refreshGeneration else { return }
            if route.routeKind == "local-thread", let threadID = route.conversationID {
                var actual = try await self.readThreadPreset(threadID)
                let cutoff = self.file.schemaVersion >= 2 ? self.file.threads[threadID]?.contextAppliedAfter : nil
                let effectiveWindow = await self.readContextWindow(threadID, actual.model,
                    cutoff.map { Date(timeIntervalSince1970: $0) })
                let confirmedRoute = try await self.currentDesktopRoute()
                guard generation == self.refreshGeneration,
                      Self.target(for: confirmedRoute) == .thread(threadID) else { return }
                actual.serviceTier = confirmedRoute.serviceTierKnown == true
                    ? confirmedRoute.serviceTier ?? "default" : "unknown"
                // 所有异步读取完成后一次提交，不在轮询中途清空已有窗口。
                actual.updatedAt = self.preset.updatedAt
                if self.target != .thread(threadID) { self.target = .thread(threadID) }
                if self.preset != actual { self.preset = actual }
                if self.effectiveContextWindow != effectiveWindow { self.effectiveContextWindow = effectiveWindow }
            } else if route.routeKind == "home" || route.routeKind == "new-thread-panel" {
                var actual = Self.readGlobalPreset()
                if route.serviceTierKnown == true { actual.serviceTier = route.serviceTier ?? "default" }
                if self.target != .home { self.target = .home }
                if self.preset != actual { self.preset = actual }
                if self.effectiveContextWindow != nil { self.effectiveContextWindow = nil }
            }
            else {
                throw CodexThemeError.downloadFailed("当前页面无法唯一识别本地对话，请打开需要控制的对话。")
            }
            self.message = self.target == .home ? "新对话默认配置；已打开的编辑器可能保留自己的选择。" : nil
        } catch {
            guard generation == self.refreshGeneration else { return }
            self.target = .unavailable(error.localizedDescription)
            self.effectiveContextWindow = nil
            self.message = error.localizedDescription
        }
    }

    func apply(
        model: String,
        reasoningEffort: String,
        serviceTier: String,
        contextWindow: Int
    ) async throws {
        guard self.isBusy == false else { return }
        let expectedTarget = self.target
        let previous = self.preset
        self.refreshGeneration += 1
        self.isBusy = true
        defer { self.isBusy = false }

        let next = CodexDesktopThreadPreset(
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            contextWindow: contextWindow,
            updatedAt: Date()
        )

        let route = try await self.currentDesktopRoute()
        guard Self.target(for: route) == expectedTarget else {
            throw CodexThemeError.downloadFailed("Codex 当前对话已变化，请等待刷新后再修改。")
        }
        switch expectedTarget {
        case .home:
            try Self.writeGlobalPreset(next)
            self.file.defaultPreset = next
            try self.persist()
            self.preset = next
            self.effectiveContextWindow = nil
            self.message = "已保存新对话默认值；已打开的编辑器可能保留自己的选择。"

        case .thread(let threadID):
            guard contextWindow == previous.contextWindow else {
                throw CodexThemeError.downloadFailed("Codex 当前协议不支持修改已加载对话的上下文窗口；这里显示最近实际窗口。可在首页设置新对话默认值。")
            }
            // 只写用户修改的字段，避免用菜单旧快照覆盖 Codex 中刚修改的其它设置。
            var params: [String: Any] = ["threadId": threadID]
            if model != previous.model { params["model"] = model }
            if reasoningEffort != previous.reasoningEffort {
                guard reasoningEffort != "default" else {
                    throw CodexThemeError.downloadFailed("请明确选择思考强度；当前协议的空值会保留原设置。")
                }
                params["effort"] = reasoningEffort
            }
            if serviceTier != previous.serviceTier { params["serviceTier"] = serviceTier }
            guard params.count > 1 else { return }
            _ = try await self.sendDesktopRequest(method: "thread/settings/update", params: params)
            let actual = try await self.readThreadPreset(threadID)
            guard (params["model"] == nil || actual.model == model),
                  (params["effort"] == nil || actual.reasoningEffort == reasoningEffort) else {
                throw CodexThemeError.downloadFailed("Codex 返回的设置与请求不一致，请刷新后重试。")
            }
            let confirmedRoute = try await self.currentDesktopRoute()
            guard Self.target(for: confirmedRoute) == expectedTarget else {
                throw CodexThemeError.downloadFailed("设置已发送到原对话，但当前页面已切换，请刷新查看。")
            }
            var confirmed = actual
            confirmed.serviceTier = confirmedRoute.serviceTierKnown == true
                ? confirmedRoute.serviceTier ?? "default" : "unknown"
            if params["serviceTier"] != nil {
                guard Self.serviceTierLabel(confirmed.serviceTier) == Self.serviceTierLabel(serviceTier) else {
                    throw CodexThemeError.downloadFailed("Codex 尚未确认速度模式，请刷新后查看。")
                }
            }
            if self.preset.model != confirmed.model { self.effectiveContextWindow = nil }
            self.preset = confirmed
            self.message = "Codex 已确认模型与思考强度；下一轮消息使用当前设置。"

        case .unavailable(let reason):
            throw CodexThemeError.downloadFailed(reason)
        }
    }

    /// 通过官方 fork 接口继承历史，在新的运行上下文中应用窗口配置。
    /// 调用前由界面明确确认创建分支；不修改原对话或全局配置。
    func createContextWindowBranch(_ window: Int, expectedTarget: Target) async throws {
        guard !self.isBusy else { return }
        guard (16_000...2_000_000).contains(window), case .thread(let sourceID) = expectedTarget else {
            throw CodexThemeError.downloadFailed("请选择有效窗口和本地对话")
        }
        self.isBusy = true
        self.isCreatingBranch = true
        self.branchProgress = "正在检查分支条件…"
        self.refreshGeneration += 1
        defer { self.isBusy = false; self.isCreatingBranch = false; self.branchProgress = nil }
        guard Self.target(for: try await self.currentDesktopRoute()) == expectedTarget else {
            throw CodexThemeError.downloadFailed("当前对话已变化，请重新选择窗口")
        }
        let source = try await self.sendDesktopRequest(method: "thread/read",
            params: ["threadId": sourceID, "includeTurns": false])
        guard let thread = source["thread"] as? [String: Any], thread["id"] as? String == sourceID,
              let status = thread["status"] as? [String: Any], status["type"] as? String == "idle" else {
            throw CodexThemeError.downloadFailed("请等待当前对话生成完成后再调整窗口")
        }
        guard Self.target(for: try await self.currentDesktopRoute()) == expectedTarget else {
            throw CodexThemeError.downloadFailed("当前对话已变化，请重新选择窗口")
        }
        self.branchProgress = "正在创建分支，可能需要约一分钟；可切换查看其他对话。"
        let result = try await self.sendDesktopRequest(method: "thread/fork", params: [
            "threadId": sourceID, "excludeTurns": true, "config": ["model_context_window": window]
        ])
        guard let created = result["thread"] as? [String: Any],
              let id = created["id"] as? String, UUID(uuidString: id) != nil, id != sourceID else {
            throw CodexThemeError.downloadFailed("Codex 未返回有效的新分支")
        }
        // 收到创建成功响应后立即保存配置，不让后续读取或导航失败丢失记录。
        let now = Date()
        let next = CodexDesktopThreadPreset(
            model: result["model"] as? String ?? thread["model"] as? String ?? self.preset.model,
            reasoningEffort: result["reasoningEffort"] as? String ?? thread["reasoningEffort"] as? String ?? "default",
            serviceTier: "unknown", contextWindow: window, updatedAt: now,
            contextAppliedAfter: now.timeIntervalSince1970)
        self.branchProgress = "分支已创建，正在保存窗口配置…"
        // 旧版本缓存曾记录未经验证的设置，不能当成新分支配置。
        if self.file.schemaVersion < 2 { self.file.threads = [:]; self.file.schemaVersion = 2 }
        self.file.threads[id] = next
        do { try self.persist() } catch {
            throw CodexThemeError.downloadFailed("分支已创建（\(id)），但保存窗口记录失败：\(error.localizedDescription)")
        }
        guard Self.target(for: try await self.currentDesktopRoute()) == expectedTarget else {
            throw CodexThemeError.downloadFailed("分支已创建（\(id)），当前页面已变化，请从 Codex 会话列表打开")
        }
        let pathData = try JSONSerialization.data(withJSONObject: ["path": "/local/" + id])
        let encoded = pathData.base64EncodedString()
        _ = try await self.evaluate("""
        (() => { const route = JSON.parse(atob('\(encoded)'));
          window.postMessage({type:'navigate-to-route',path:route.path}, '*'); return true; })()
        """)
        // 导航后交还普通轮询；不占用写入锁等待页面挂载。
        self.message = "分支已创建，配置窗口 \(window)；实际可用窗口待下一轮上报。"
    }

    private func readThreadPreset(_ threadID: String) async throws -> CodexDesktopThreadPreset {
        let result = try await self.sendDesktopRequest(
            method: "thread/read", params: ["threadId": threadID, "includeTurns": false]
        )
        guard let thread = result["thread"] as? [String: Any],
              thread["id"] as? String == threadID,
              let model = thread["model"] as? String, !model.isEmpty else {
            throw CodexThemeError.downloadFailed("Codex 未返回当前对话的真实模型设置")
        }
        return CodexDesktopThreadPreset(
            model: model,
            reasoningEffort: thread["reasoningEffort"] as? String ?? "default",
            serviceTier: "unknown",
            contextWindow: self.file.schemaVersion >= 2 ? self.file.threads[threadID]?.contextWindow
                ?? CodexBarGlobalSettings.defaultContextWindow(for: model)
                : CodexBarGlobalSettings.defaultContextWindow(for: model),
            updatedAt: Date()
        )
    }

    private static func target(for route: DesktopRoute) -> Target {
        if route.routeKind == "local-thread", let id = route.conversationID { return .thread(id) }
        if route.routeKind == "home" || route.routeKind == "new-thread-panel" { return .home }
        return .unavailable("无法识别当前页面")
    }

    // MARK: - 桌面桥接

    private struct DesktopRoute: Decodable {
        let routeKind: String
        let conversationID: String?
        let serviceTierKnown: Bool?
        let serviceTier: String?
    }

    private func currentDesktopRoute() async throws -> DesktopRoute {
        let script: String
        if let routeScript = self.routeScript {
            script = routeScript
        } else {
            guard let url = Bundle.main.url(forResource: "desktop-thread-route", withExtension: "js") else {
                throw CodexThemeError.downloadFailed("会话识别脚本缺失")
            }
            script = try String(contentsOf: url, encoding: .utf8)
        }
        guard let value = try await self.evaluate(script) as? String,
              let data = value.data(using: .utf8) else {
            throw CodexThemeError.downloadFailed("无法识别 Codex 当前对话")
        }
        return try JSONDecoder().decode(DesktopRoute.self, from: data)
    }

    private func sendDesktopRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestObject: [String: Any] = ["method": method, "params": params]
        let requestData = try JSONSerialization.data(withJSONObject: requestObject)
        let encoded = requestData.base64EncodedString()
        let script = #"""
        (() => new Promise((resolve) => {
          const payload = JSON.parse(atob('\#(encoded)'));
          const requestId = `codex-box-${Date.now()}-${Math.random().toString(16).slice(2)}`;
          const timeoutMs = \#(method == "thread/fork" ? 60000 : 10000);
          let finished = false;
          const finish = (value) => {
            if (finished) return;
            finished = true;
            window.removeEventListener('message', listener);
            clearTimeout(timer);
            resolve(JSON.stringify(value));
          };
          const listener = (event) => {
            const envelope = event.data;
            const response = envelope?.message ?? envelope?.response;
            if (envelope?.type !== 'mcp-response' || String(response?.id) !== requestId) return;
            if (response.error) finish({ok:false,error:response.error});
            else {
              let result = response.result ?? {};
              if (payload.method === 'thread/fork') {
                // fork 携带全部历史；这里只传回配置元数据，避免大对话序列化阻塞页面。
                result = {thread:{id:result.thread?.id},model:result.model,reasoningEffort:result.reasoningEffort};
              }
              finish({ok:true,result});
            }
          };
          const timer = setTimeout(() => finish({ok:false,error:{message:'Codex 桌面请求超时'}}), timeoutMs + 2000);
          window.addEventListener('message', listener);
          window.electronBridge.sendMessageFromView({
            type:'mcp-request',hostId:'local',priority:'critical',source:'thread',timeoutMs,
            expiresAtMs:Date.now()+timeoutMs,
            request:{id:requestId,method:payload.method,params:payload.params}
          }).catch(error => finish({ok:false,error:{message:String(error)}}));
        }))()
        """#
        guard let value = try await self.evaluate(script) as? String,
              let data = value.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodexThemeError.downloadFailed("Codex 桌面返回格式无效") }
        guard envelope["ok"] as? Bool == true else {
            let error = envelope["error"] as? [String: Any]
            throw CodexThemeError.downloadFailed(error?["message"] as? String ?? "Codex 桌面请求失败")
        }
        return envelope["result"] as? [String: Any] ?? [:]
    }

    // MARK: - 持久化与全局默认值

    private static func readFile() -> CodexDesktopThreadPresetFile? {
        guard let data = try? Data(contentsOf: CodexPaths.desktopThreadPresetsURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexDesktopThreadPresetFile.self, from: data)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self.file)
        if let persistOverride { try persistOverride(data); return }
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(
            data,
            to: CodexPaths.desktopThreadPresetsURL
        )
    }

    private static func readGlobalPreset() -> CodexDesktopThreadPreset {
        guard let text = try? String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8) else {
            return .fallback
        }
        func unquote(_ value: String?) -> String? {
            guard var value else { return nil }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst(); value.removeLast()
            }
            return value
        }
        let model = unquote(CodexGatewayCoordinator.rootValue(in: text, key: "model"))
            ?? CodexBarGlobalSettings.defaultModelID
        let effort = unquote(CodexGatewayCoordinator.rootValue(in: text, key: "model_reasoning_effort"))
            ?? "medium"
        let tier = unquote(CodexGatewayCoordinator.rootValue(in: text, key: "service_tier"))
            ?? "flex"
        let context = Int(CodexGatewayCoordinator.rootValue(in: text, key: "model_context_window") ?? "")
            ?? CodexBarGlobalSettings.defaultContextWindow(for: model)
        return CodexDesktopThreadPreset(
            model: model,
            reasoningEffort: effort,
            serviceTier: tier,
            contextWindow: context,
            updatedAt: .distantPast
        )
    }

    private static func writeGlobalPreset(_ preset: CodexDesktopThreadPreset) throws {
        let url = CodexPaths.configTomlURL
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var updated = CodexGatewayCoordinator.upsertRootKey(
            in: original, key: "model", value: "\"\(preset.model)\""
        )
        updated = CodexGatewayCoordinator.upsertRootKey(
            in: updated, key: "model_reasoning_effort", value: "\"\(preset.reasoningEffort)\""
        )
        updated = CodexGatewayCoordinator.upsertRootKey(
            in: updated, key: "service_tier", value: "\"\(preset.serviceTier)\""
        )
        updated = CodexGatewayCoordinator.upsertRootKey(
            in: updated, key: "model_context_window", value: "\(preset.contextWindow)"
        )
        try CodexPaths.writeSecureFile(Data(updated.utf8), to: url)
    }

}
