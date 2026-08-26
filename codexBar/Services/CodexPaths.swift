import Foundation

enum CodexPaths {
    private static let stateSQLiteDefaultVersion = 5
    private static let logsSQLiteDefaultVersion = 2

    static var realHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEXBAR_HOME"],
           override.isEmpty == false {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var codexRoot: URL {
        self.realHome.appendingPathComponent(".codex", isDirectory: true)
    }

    /// 本项目的数据目录：`~/.codex-box`。
    ///
    /// 上游（codexbar）用的是 `~/.codexbar`。首次访问时若发现旧目录存在而新目录不存在，
    /// 会整体搬迁过来，避免改名导致既有账号、主题、档案配置全部丢失。
    static var codexBarRoot: URL {
        let root = self.realHome.appendingPathComponent(".codex-box", isDirectory: true)
        self.migrateLegacyRootIfNeeded(to: root)
        return root
    }

    /// 上游（codexbar）使用的旧目录名，仅用于一次性迁移
    private static let legacyRootName = ".codexbar"
    private nonisolated(unsafe) static var didAttemptRootMigration = false

    private static func migrateLegacyRootIfNeeded(to root: URL) {
        guard self.didAttemptRootMigration == false else { return }
        self.didAttemptRootMigration = true

        let fileManager = FileManager.default
        let legacy = self.realHome.appendingPathComponent(self.legacyRootName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path),
              fileManager.fileExists(atPath: root.path) == false
        else { return }

        // 用复制而非移动：万一中途失败，旧目录仍然完好，用户不会丢数据。
        try? fileManager.copyItem(at: legacy, to: root)
    }

    static var authURL: URL { self.codexRoot.appendingPathComponent("auth.json") }
    static var tokenPoolURL: URL { self.codexRoot.appendingPathComponent("token_pool.json") }
    static var configTomlURL: URL { self.codexRoot.appendingPathComponent("config.toml") }
    static var providerSecretsURL: URL { self.codexRoot.appendingPathComponent("provider-secrets.env") }
    static var stateSQLiteURL: URL {
        self.versionedSQLiteURL(
            basename: "state",
            defaultVersion: self.stateSQLiteDefaultVersion
        )
    }
    static var logsSQLiteURL: URL {
        self.versionedSQLiteURL(
            basename: "logs",
            defaultVersion: self.logsSQLiteDefaultVersion
        )
    }
    static var oauthFlowsDirectoryURL: URL { self.codexBarRoot.appendingPathComponent("oauth-flows", isDirectory: true) }
    static var menuHostRootURL: URL { self.codexBarRoot.appendingPathComponent("menu-host", isDirectory: true) }
    static var menuHostAppURL: URL { self.menuHostRootURL.appendingPathComponent("codexbar.app", isDirectory: true) }
    static var menuHostLeaseURL: URL { self.menuHostRootURL.appendingPathComponent("host.pid") }

    static var barConfigURL: URL { self.codexBarRoot.appendingPathComponent("config.json") }
    static var costCacheURL: URL { self.codexBarRoot.appendingPathComponent("cost-cache.json") }
    static var costSessionCacheURL: URL { self.codexBarRoot.appendingPathComponent("cost-session-cache.json") }
    static var costEventLedgerURL: URL { self.codexBarRoot.appendingPathComponent("cost-event-ledger.json") }
    static var switchJournalURL: URL { self.codexBarRoot.appendingPathComponent("switch-journal.jsonl") }
    static var managedLaunchRootURL: URL { self.codexBarRoot.appendingPathComponent("managed-launch", isDirectory: true) }
    static var managedLaunchBinURL: URL { self.managedLaunchRootURL.appendingPathComponent("bin", isDirectory: true) }
    static var managedLaunchHitsURL: URL { self.managedLaunchRootURL.appendingPathComponent("hits", isDirectory: true) }
    static var managedLaunchStateURL: URL { self.managedLaunchRootURL.appendingPathComponent("last-launch.json") }
    static var managedCodexDesktopProfilesURL: URL { self.managedLaunchRootURL.appendingPathComponent("codex-desktop-profiles", isDirectory: true) }
    static var openAIGatewayRootURL: URL { self.codexBarRoot.appendingPathComponent("openai-gateway", isDirectory: true) }
    static var openAIGatewayStateURL: URL { self.openAIGatewayRootURL.appendingPathComponent("state.json") }
    static var openAIGatewayRouteJournalURL: URL { self.openAIGatewayRootURL.appendingPathComponent("route-journal.json") }
    static var openRouterGatewayRootURL: URL { self.codexBarRoot.appendingPathComponent("openrouter-gateway", isDirectory: true) }
    static var openRouterGatewayStateURL: URL { self.openRouterGatewayRootURL.appendingPathComponent("state.json") }

    static var configBackupURL: URL { self.codexRoot.appendingPathComponent("config.toml.bak-codexbar-last") }
    static var authBackupURL: URL { self.codexRoot.appendingPathComponent("auth.json.bak-codexbar-last") }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: self.codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexBarRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.oauthFlowsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managedLaunchBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managedLaunchHitsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.managedCodexDesktopProfilesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.openAIGatewayRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.openRouterGatewayRootURL, withIntermediateDirectories: true)
    }

    static func writeSecureFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        try data.write(to: tempURL, options: .atomic)
        try self.applySecurePermissions(to: tempURL)

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
        try self.applySecurePermissions(to: url)
    }

    static func backupFileIfPresent(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        try self.writeSecureFile(data, to: destination)
    }

    private static func applySecurePermissions(to url: URL) throws {
        try FileManager.default.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: url.path)
    }

    private static func versionedSQLiteURL(
        basename: String,
        defaultVersion: Int
    ) -> URL {
        let version = self.latestSQLiteVersion(basename: basename) ?? defaultVersion
        return self.codexRoot.appendingPathComponent("\(basename)_\(version).sqlite")
    }

    private static func latestSQLiteVersion(basename: String) -> Int? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: self.codexRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let prefix = "\(basename)_"
        return urls.compactMap { url -> Int? in
            guard url.pathExtension == "sqlite" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }

            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(prefix) else { return nil }
            let suffix = String(filename.dropFirst(prefix.count))
            return Int(suffix)
        }
        .max()
    }
}
