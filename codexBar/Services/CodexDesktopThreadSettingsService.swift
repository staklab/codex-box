import Combine
import Foundation

struct CodexDesktopThreadPreset: Codable, Equatable {
    var model: String
    var reasoningEffort: String
    var serviceTier: String
    var contextWindow: Int
    var updatedAt: Date

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
/// - 只发送 `thread/settings/update` 与 `thread/resume`；
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
    @Published private(set) var message: String?

    private let injection: CodexSkinInjectionService
    private var file: CodexDesktopThreadPresetFile
    private var refreshGeneration = 0

    init(injection: CodexSkinInjectionService = .shared) {
        self.injection = injection
        let defaultPreset = Self.readGlobalPreset()
        self.file = Self.readFile() ?? CodexDesktopThreadPresetFile(
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
            return "未连接"
        }
    }

    /// 当前线程以 Codex 最近一次 token_count 上报的有效窗口为准；首页或尚未产生
    /// token_count 的新线程仍显示用户配置值。
    var displayedContextWindow: Int {
        self.effectiveContextWindow ?? self.preset.contextWindow
    }

    func refresh() async {
        self.refreshGeneration += 1
        let generation = self.refreshGeneration
        do {
            let route = try await self.currentDesktopRoute()
            guard generation == self.refreshGeneration else { return }
            if route.routeKind == "local-thread", let threadID = route.conversationID {
                self.target = .thread(threadID)
                self.preset = self.file.threads[threadID] ?? Self.readGlobalPreset()
                self.effectiveContextWindow = nil

                let stateDBURL = CodexPaths.stateSQLiteURL
                let effectiveWindow = await Task.detached(priority: .utility) {
                    CodexThreadContextWindowReader(stateDBURL: stateDBURL)
                        .latestEffectiveContextWindow(threadID: threadID)
                }.value
                guard generation == self.refreshGeneration,
                      self.target == .thread(threadID)
                else { return }
                self.effectiveContextWindow = effectiveWindow
            } else {
                self.target = .home
                self.preset = self.file.defaultPreset
                self.effectiveContextWindow = nil
            }
            self.message = nil
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
        self.isBusy = true
        defer { self.isBusy = false }

        let next = CodexDesktopThreadPreset(
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            contextWindow: contextWindow,
            updatedAt: Date()
        )

        switch self.target {
        case .home:
            try Self.writeGlobalPreset(next)
            self.file.defaultPreset = next
            try self.persist()
            self.preset = next
            self.effectiveContextWindow = nil
            self.message = "已更新新对话默认值；无需重启。"

        case .thread(let threadID):
            _ = try await self.sendDesktopRequest(
                method: "thread/settings/update",
                params: [
                    "threadId": threadID,
                    "model": model,
                    "effort": reasoningEffort,
                    "serviceTier": serviceTier,
                ]
            )
            _ = try await self.sendDesktopRequest(
                method: "thread/resume",
                params: [
                    "threadId": threadID,
                    "excludeTurns": true,
                    "model": model,
                    "serviceTier": serviceTier,
                    "config": [
                        "model_context_window": contextWindow,
                        "model_reasoning_effort": reasoningEffort,
                    ],
                ]
            )
            self.file.threads[threadID] = next
            try self.persist()
            self.preset = next
            // 新配置会在下一轮消息产生新的 token_count 后被重新识别。
            self.effectiveContextWindow = nil
            self.message = "已应用到当前对话；下一轮消息生效，无需重启。"

        case .unavailable(let reason):
            throw CodexThemeError.downloadFailed(reason)
        }
    }

    // MARK: - 桌面桥接

    private struct DesktopRoute: Decodable {
        let routeKind: String
        let conversationID: String?
    }

    private func currentDesktopRoute() async throws -> DesktopRoute {
        let script = #"""
        (() => {
          const root = window.__codexRoot?._internalRoot?.current;
          if (!root) return JSON.stringify({routeKind:'unavailable',conversationID:null});
          const routes = [];
          const seenFibers = new Set(), seenObjects = new WeakSet(), stack = [root];
          const scan = (value, depth = 0) => {
            if (depth > 5 || value == null || typeof value !== 'object' || seenObjects.has(value)) return;
            seenObjects.add(value);
            try {
              if (typeof value.routeKind === 'string') {
                routes.push({routeKind:value.routeKind,conversationID:typeof value.conversationId==='string'?value.conversationId:null});
              }
              for (const key of Object.keys(value).slice(0,100)) {
                if (/children|return|child|sibling|stateNode|alternate|_owner/i.test(key)) continue;
                scan(value[key], depth + 1);
              }
            } catch (_) {}
          };
          let count = 0;
          while (stack.length && count < 50000) {
            const fiber = stack.pop();
            if (!fiber || seenFibers.has(fiber)) continue;
            seenFibers.add(fiber); count++;
            scan(fiber.memoizedProps); scan(fiber.pendingProps); scan(fiber.memoizedState);
            if (fiber.child) stack.push(fiber.child);
            if (fiber.sibling) stack.push(fiber.sibling);
          }
          const active = routes.find(route => route.routeKind === 'local-thread' && route.conversationID);
          if (active) return JSON.stringify(active);
          const home = routes.find(route => route.routeKind === 'home' || route.routeKind === 'new-thread-panel');
          return JSON.stringify(home ?? {routeKind:'unavailable',conversationID:null});
        })()
        """#
        guard let value = try await self.injection.evaluateDesktop(javascript: script) as? String,
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
            else finish({ok:true,result:response.result ?? {}});
          };
          const timer = setTimeout(() => finish({ok:false,error:{message:'Codex 桌面请求超时'}}), 12000);
          window.addEventListener('message', listener);
          window.electronBridge.sendMessageFromView({
            type:'mcp-request',hostId:'local',priority:'critical',source:'thread',timeoutMs:10000,
            expiresAtMs:Date.now()+10000,
            request:{id:requestId,method:payload.method,params:payload.params}
          }).catch(error => finish({ok:false,error:{message:String(error)}}));
        }))()
        """#
        guard let value = try await self.injection.evaluateDesktop(javascript: script) as? String,
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
        try CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(
            try encoder.encode(self.file),
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
