import AppKit
import Combine
import Foundation

/// 一个 Codex 运行档案：绑定独立的 CODEX_HOME 目录。
///
/// 设计要点：每个账号一个 profile，各自持有独立的 `auth.json` / `sessions` / `state.db`。
/// 这样多个账号可以同时跑，且**永远不会共享同一份 auth.json**——
/// 而共享 auth.json 正是 refresh token 被反复轮换作废、导致 Codex 反复掉登录的根因。
struct CodexProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var accountEmail: String?
    var lastLaunchedAt: Date?

    /// 该 profile 独占的 CODEX_HOME 绝对路径。
    var codexHomePath: String

    var codexHomeURL: URL {
        URL(fileURLWithPath: self.codexHomePath, isDirectory: true)
    }
}

struct CodexProfileStoreFile: Codable {
    var schemaVersion: Int
    var profiles: [CodexProfile]

    static let empty = CodexProfileStoreFile(schemaVersion: 1, profiles: [])
}

enum CodexProfileError: LocalizedError {
    case invalidName
    case duplicateName(String)
    case codexExecutableMissing
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "档案名称不能为空"
        case .duplicateName(let name):
            return "已存在同名档案：\(name)"
        case .codexExecutableMissing:
            return "找不到 codex 可执行文件（请确认已安装 Codex 桌面版）"
        case .launchFailed(let message):
            return "启动失败：\(message)"
        }
    }
}

extension CodexPaths {
    /// `~/.codexbar/profiles.json`
    static var profileStoreURL: URL {
        self.codexBarRoot.appendingPathComponent("profiles.json")
    }

    /// `~/.codexbar/profiles/`
    static var profilesRootURL: URL {
        self.codexBarRoot.appendingPathComponent("profiles", isDirectory: true)
    }
}

@MainActor
final class CodexProfileService: ObservableObject {
    static let shared = CodexProfileService()

    @Published private(set) var profiles: [CodexProfile] = []

    private let fileManager: FileManager
    private let now: () -> Date

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now
        self.profiles = Self.readStore(fileManager: fileManager).profiles
    }

    // MARK: - 读写

    private static func readStore(fileManager: FileManager) -> CodexProfileStoreFile {
        guard let data = try? Data(contentsOf: CodexPaths.profileStoreURL) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CodexProfileStoreFile.self, from: data)) ?? .empty
    }

    func reload() {
        self.profiles = Self.readStore(fileManager: self.fileManager).profiles
    }

    private func persist() throws {
        try CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = CodexProfileStoreFile(schemaVersion: 1, profiles: self.profiles)
        let data = try encoder.encode(file)
        try CodexPaths.writeSecureFile(data, to: CodexPaths.profileStoreURL)
    }

    // MARK: - 增删

    @discardableResult
    func createProfile(name: String, accountEmail: String? = nil) throws -> CodexProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw CodexProfileError.invalidName }
        guard self.profiles.contains(where: { $0.name == trimmed }) == false else {
            throw CodexProfileError.duplicateName(trimmed)
        }

        let slug = Self.slugify(trimmed, existing: Set(self.profiles.map(\.id)))
        let homeURL = CodexPaths.profilesRootURL
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let profile = CodexProfile(
            id: slug,
            name: trimmed,
            accountEmail: accountEmail,
            lastLaunchedAt: nil,
            codexHomePath: homeURL.path
        )
        self.profiles.append(profile)
        try self.persist()
        return profile
    }

    /// 删除档案记录。`removeData` 为 true 时把整个 CODEX_HOME 目录移入废纸篓
    /// （用移动而非直接删除，避免误删无法挽回）。
    func deleteProfile(id: String, removeData: Bool) throws {
        guard let index = self.profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = self.profiles[index]
        self.profiles.remove(at: index)
        try self.persist()

        if removeData {
            let container = profile.codexHomeURL.deletingLastPathComponent()
            var trashed: NSURL?
            try? self.fileManager.trashItem(at: container, resultingItemURL: &trashed)
        }
    }

    // MARK: - 登录状态

    /// 以该 profile 的 CODEX_HOME 查询登录状态。只读，不会触发 token 刷新。
    func loginStatus(for profile: CodexProfile) -> String {
        guard let codexURL = Self.resolveCodexExecutable() else { return "未找到 codex" }
        let process = Process()
        process.executableURL = codexURL
        process.arguments = ["login", "status"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.codexHomePath
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "查询失败"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - 启动

    /// 在新的终端窗口里，以该 profile 的 CODEX_HOME 启动 codex CLI。
    ///
    /// 用 CLI 而非桌面 GUI，是因为 ChatGPT.app 在 prod 构建下强制单实例
    /// （`requestSingleInstanceLock`），第二个 GUI 实例会被立即接管退出；
    /// 而 codex CLI 完全尊重 CODEX_HOME，可以任意多开。
    func launchCLI(profile: CodexProfile, workingDirectory: String?) throws {
        guard let codexURL = Self.resolveCodexExecutable() else {
            throw CodexProfileError.codexExecutableMissing
        }

        let scriptURL = CodexPaths.profilesRootURL
            .appendingPathComponent(profile.id, isDirectory: true)
            .appendingPathComponent("launch.command")

        let workdirLine: String
        if let workingDirectory, workingDirectory.isEmpty == false {
            workdirLine = "cd \(Self.shellQuoted(workingDirectory))"
        } else {
            workdirLine = "cd \"$HOME\""
        }

        let script = """
        #!/bin/sh
        # 由 codex-box 生成：为档案「\(profile.name)」启动隔离的 codex 会话
        export CODEX_HOME=\(Self.shellQuoted(profile.codexHomePath))
        \(workdirLine)
        echo "档案: \(profile.name)"
        echo "CODEX_HOME: $CODEX_HOME"
        echo
        exec \(Self.shellQuoted(codexURL.path))
        """

        try self.fileManager.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [scriptURL],
            withApplicationAt: terminalURL,
            configuration: configuration,
            completionHandler: nil
        )

        if let index = self.profiles.firstIndex(where: { $0.id == profile.id }) {
            self.profiles[index].lastLaunchedAt = self.now()
            try? self.persist()
        }
    }

    // MARK: - 工具

    /// 定位 codex 可执行文件。注意 bundle id 是 com.openai.codex，
    /// 但应用实际叫 ChatGPT.app（上游探针里写死 "Codex.app" 是个 bug，这里不重蹈覆辙）。
    static func resolveCodexExecutable() -> URL? {
        var candidates: [URL] = []
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(appURL)
        }
        candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        candidates.append(URL(fileURLWithPath: "/Applications/Codex.app"))

        for appURL in candidates {
            let executable = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable
            }
        }

        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func slugify(_ value: String, existing: Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = value.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "profile" }

        guard existing.contains(slug) else { return slug }
        var suffix = 2
        while existing.contains("\(slug)-\(suffix)") { suffix += 1 }
        return "\(slug)-\(suffix)"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
