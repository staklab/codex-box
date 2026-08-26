import AppKit
import Combine
import Foundation

/// 账号网关协调器：让 Codex 通过 codexbar 的本地网关发请求，从而在不改写
/// `~/.codex/auth.json` 的前提下切换账号。
///
/// 为什么不用"写 auth.json 切账号"：
/// OpenAI 的 refresh token 是一次性轮换的，Codex 桌面版和 codex-box 各写各的
/// 会互相作废对方的凭据，表现就是反复掉登录。网关方案里凭据只在**请求头**上
/// 按账号注入，`auth.json` 全程不动。
///
/// ⚠️ 代价（务必知情）：启用后 Codex 的出口指向 `127.0.0.1:1456`，
/// **网关不在跑时 Codex 就发不出请求**。因此本协调器做了三重保护：
/// 1. 默认关闭，只有显式启用才写配置；
/// 2. codexbar 退出时自动还原（`restoreOnTerminate`）；
/// 3. 提供「紧急还原」入口，任何时候可一键退回官方直连。
@MainActor
final class CodexGatewayCoordinator: ObservableObject {
    static let shared = CodexGatewayCoordinator()

    /// 写进 config.toml 的 provider 名
    static let providerName = "codex-box"
    static let officialProvider = "openai"

    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    private let gateway: OpenAIAccountGatewayControlling
    private let fileManager: FileManager

    init(
        gateway: OpenAIAccountGatewayControlling = OpenAIAccountGatewayService.shared,
        fileManager: FileManager = .default
    ) {
        self.gateway = gateway
        self.fileManager = fileManager
        self.isEnabled = Self.configPointsAtGateway()
    }

    // MARK: - 开关

    func enable() throws {
        self.gateway.startIfNeeded()
        try self.writeGatewayProvider()
        self.isEnabled = true
        self.lastError = nil
    }

    func disable() throws {
        try self.restoreOfficialProvider()
        self.gateway.stop()
        self.isEnabled = false
        self.lastError = nil
    }

    /// 应用退出时调用：无论当前状态如何，都把 Codex 的出口还原成官方直连，
    /// 避免 codex-box 关掉之后 Codex 停在指向死网关的状态上。
    func restoreOnTerminate() {
        guard Self.configPointsAtGateway() else { return }
        try? self.restoreOfficialProvider()
        self.gateway.stop()
    }

    // MARK: - config.toml 外科手术

    /// 只动两处：根键 `model_provider`，以及 `[model_providers.codexbar]` 这张表。
    /// 其余内容逐字节保留；写入前先备份。
    private func writeGatewayProvider() throws {
        let configURL = CodexPaths.configTomlURL
        guard let original = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw CodexThemeError.configMissing
        }

        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.bak-codexbar-gateway")
        try? Data(original.utf8).write(to: backupURL, options: .atomic)

        var updated = CodexThemeService.replaceTable(
            in: original,
            table: "model_providers.\(Self.providerName)",
            body: [
                "name = \"codex-box gateway\"",
                "wire_api = \"responses\"",
                "requires_openai_auth = true",
                "base_url = \"\(OpenAIAccountGatewayConfiguration.baseURLString)\"",
            ]
        )
        updated = Self.upsertRootKey(
            in: updated,
            key: "model_provider",
            value: "\"\(Self.providerName)\""
        )

        try CodexPaths.writeSecureFile(Data(updated.utf8), to: configURL)
    }

    private func restoreOfficialProvider() throws {
        let configURL = CodexPaths.configTomlURL
        guard let original = try? String(contentsOf: configURL, encoding: .utf8) else { return }

        var updated = Self.upsertRootKey(
            in: original,
            key: "model_provider",
            value: "\"\(Self.officialProvider)\""
        )
        updated = CodexThemeService.removeTable(
            in: updated,
            table: "model_providers.\(Self.providerName)"
        )
        try CodexPaths.writeSecureFile(Data(updated.utf8), to: configURL)
    }

    static func configPointsAtGateway() -> Bool {
        guard let text = try? String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8) else {
            return false
        }
        return self.rootValue(in: text, key: "model_provider") == "\"\(self.providerName)\""
    }

    // MARK: - 根级键读写
    //
    // TOML 的根级键必须位于第一个 `[table]` 之前，否则会被解析成那张表的成员。
    // CodexThemeService 里的表级工具不适用于根键，因此单独实现。

    static func rootValue(in content: String, key: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            return String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func upsertRootKey(in content: String, key: String, value: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var firstTableIndex = lines.count

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                firstTableIndex = index
                break
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            if name == key {
                lines[index] = "\(key) = \(value)"
                return lines.joined(separator: "\n")
            }
        }

        lines.insert("\(key) = \(value)", at: firstTableIndex)
        return lines.joined(separator: "\n")
    }
}
