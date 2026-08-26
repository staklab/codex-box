import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - 市场模型

/// 皮肤市场索引里的一条主题。
/// 上游索引托管在 GitHub raw，**不提供 sha256**，因此本地采用 TOFU（首次信任并钉住哈希）：
/// 安装时算出摘要存下来，后续同版本内容若发生变化即可被检出。
struct CodexThemeListing: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    var author: String?
    var description: String?
    var license: String?
    var sourceUrl: String?
    var tags: [String]?

    /// 索引内的相对路径
    let theme: String
    var image: String?
    var preview: String?

    /// 该条目来自哪个源（解码后由服务回填，不来自 JSON）
    var sourceBaseURL: String?
    var sourceName: String?

    /// 该条目是 `.codexskin` 压缩包（awesome-codex-skins 格式），
    /// `theme` 字段存的是包路径而非 theme.json 路径。
    var isPack: Bool?
    /// 上游声明的包摘要，安装时强校验
    var declaredSha256: String?

    /// 部分源（dreamskin.cc）在列表里就内嵌了配色，
    /// 这种情况下换配色无需下载安装包。
    var inlineColors: CodexThemeDefinition.Colors?
    var inlineAppearance: String?
}

/// 一个皮肤库。任何发布了同 schema `index.json` 的仓库都能作为源接入。
enum CodexThemeSourceFormat: String, Codable {
    /// CodexPlusPlus-Themes：`index.json` 里 themes[]，资源为相对路径
    case codexPlusPlus
    /// awesome-codex-skins：`index.json` 里 skins[]，每套是 .codexskin 压缩包
    case codexSkinPack
    /// dreamskin.cc：分页 REST API，颜色内嵌在 displayMeta，无需下载包即可换配色
    case dreamSkinAPI
}

struct CodexThemeSource: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// 索引位于 `<baseURL>/index.json`，资源相对该基址解析
    var baseURL: String
    var enabled: Bool
    var format: CodexThemeSourceFormat = .codexPlusPlus

    static let builtins: [CodexThemeSource] = [
        CodexThemeSource(
            id: "codexplusplus",
            name: "CodexPlusPlus Themes（聚合库）",
            baseURL: "https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlus-Themes/main",
            enabled: true,
            format: .codexPlusPlus
        ),
        CodexThemeSource(
            id: "dreamskin-cc",
            name: "DreamSkin.cc（社区大库）",
            baseURL: "https://api.dreamskin.cc",
            enabled: true,
            format: .dreamSkinAPI
        ),
        CodexThemeSource(
            id: "awesome-codex-skins",
            name: "Awesome Codex Skins（.codexskin 标准库）",
            baseURL: "https://raw.githubusercontent.com/Wangnov/awesome-codex-skins/main/dist-catalog",
            enabled: true,
            format: .codexSkinPack
        ),
        // 下面几个是原始作者仓库。它们目前没有发布 index.json，
        // 内容已被上面的聚合库收录；保留条目是为了将来它们自建索引时可直接启用。
        CodexThemeSource(
            id: "dream-skin",
            name: "Codex Dream Skin（原作者库）",
            baseURL: "https://raw.githubusercontent.com/Fei-Away/Codex-Dream-Skin/main",
            enabled: false
        ),
        CodexThemeSource(
            id: "skin-packs",
            name: "Codex Skin Packs",
            baseURL: "https://raw.githubusercontent.com/ChannelerH/codex-skin-packs/main",
            enabled: false
        ),
        CodexThemeSource(
            id: "snow-skin",
            name: "Codex Snow Skin",
            baseURL: "https://raw.githubusercontent.com/chaoran162/Codex-Snow-Skin/main",
            enabled: false
        ),
    ]
}

struct CodexThemeSourcesFile: Codable {
    var schemaVersion: Int
    var sources: [CodexThemeSource]
}

struct CodexThemeMarketIndex: Codable {
    let schemaVersion: Int
    let themes: [CodexThemeListing]
}

/// `awesome-codex-skins` 的目录格式：条目在 `skins` 下，
/// 每套主题是一个 `.codexskin` 压缩包，且**上游提供 sha256**（比 TOFU 更强）。
struct CodexSkinPackCatalog: Codable {
    struct Entry: Codable {
        let id: String
        let name: String
        var description: String?
        let version: String
        var author: String?
        var appearance: String?
        var license: String?
        var tags: [String]?
        var sha256: String?
        /// 包的相对路径，例如 packs/asuka-eva02-1.0.0.codexskin
        let pack: String
        var preview: String?
    }

    let schemaVersion: Int
    var source: String?
    let skins: [Entry]
}

/// dream-skin 的主题定义（与 Codex++ / Codex-Dream-Skin 同 schema）
struct CodexThemeDefinition: Codable, Equatable {
    struct Colors: Codable, Equatable {
        var background: String?
        var panel: String?
        var panelAlt: String?
        var accent: String?
        var accentAlt: String?
        var secondary: String?
        var highlight: String?
        var text: String?
        var muted: String?
        var line: String?
    }

    var schemaVersion: Int?
    var id: String?
    var name: String?
    var brandSubtitle: String?
    var tagline: String?
    var colors: Colors
    var image: String?
    /// "light" / "dark"
    var appearance: String?
}

struct CodexInstalledTheme: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var installedAt: Date
    /// TOFU 钉住的摘要
    var themeSha256: String
    var imageSha256: String?
    var hasImage: Bool
}

struct CodexThemeInstallState: Codable {
    var schemaVersion: Int
    var installed: [CodexInstalledTheme]
    var appliedThemeID: String?

    static let empty = CodexThemeInstallState(schemaVersion: 1, installed: [], appliedThemeID: nil)
}

enum CodexThemeError: LocalizedError {
    case badIndex
    case themeNotFound(String)
    case downloadFailed(String)
    case integrityMismatch(String)
    case configMissing

    var errorDescription: String? {
        switch self {
        case .badIndex:
            return "皮肤市场索引解析失败"
        case .themeNotFound(let id):
            return "市场中没有这个主题：\(id)"
        case .downloadFailed(let detail):
            return "下载失败：\(detail)"
        case .integrityMismatch(let id):
            return "主题 \(id) 的内容与首次安装时不一致（摘要不匹配），已中止"
        case .configMissing:
            return "找不到 ~/.codex/config.toml"
        }
    }
}

extension CodexPaths {
    static var themesRootURL: URL {
        self.codexBarRoot.appendingPathComponent("themes", isDirectory: true)
    }

    static var themeStateURL: URL {
        self.codexBarRoot.appendingPathComponent("themes-state.json")
    }

    static var themeSourcesURL: URL {
        self.codexBarRoot.appendingPathComponent("theme-sources.json")
    }

    /// 本地皮肤库根目录：市场之外自己收藏/导入的主题放这里
    static var localThemesRootURL: URL {
        self.codexBarRoot.appendingPathComponent("themes-local", isDirectory: true)
    }
}

/// dreamskin.cc 的分页响应。
/// 关键优势：`displayMeta.colors` 直接内嵌配色，换配色无需下载安装包，
/// 只有需要壁纸时才去拉 `/v1/themes/{id}/download`。
struct CodexDreamSkinPage: Codable {
    struct Item: Codable {
        struct DisplayMeta: Codable {
            var colors: CodexThemeDefinition.Colors?
            var appearance: String?
        }

        let id: String
        var themeId: String?
        var slug: String?
        let name: String
        var version: String?
        var authorDisplayName: String?
        var license: String?
        var packageSha256: String?
        var packageBytes: Int?
        var downloadCount: Int?
        var displayMeta: DisplayMeta?
    }

    let items: [Item]
    let total: Int
    let limit: Int
    let offset: Int
}

// MARK: - 服务

@MainActor
final class CodexThemeService: ObservableObject {
    static let shared = CodexThemeService()

    static let marketBaseURL = "https://raw.githubusercontent.com/BigPizzaV3/CodexPlusPlus-Themes/main"

    /// 本地库条目的 `sourceBaseURL` 标记值（不是真实 URL）
    static let localSourceMarker = "local://"

    @Published private(set) var listings: [CodexThemeListing] = []
    @Published private(set) var state: CodexThemeInstallState = .empty
    @Published private(set) var isLoadingMarket = false
    @Published private(set) var lastRefreshIssues: [String] = []
    @Published var sources: [CodexThemeSource] = CodexThemeSource.builtins

    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        self.state = Self.readState()
        self.sources = Self.readSources()
        try? fileManager.createDirectory(
            at: CodexPaths.localThemesRootURL,
            withIntermediateDirectories: true
        )
    }

    private static func readSources() -> [CodexThemeSource] {
        guard let data = try? Data(contentsOf: CodexPaths.themeSourcesURL),
              let file = try? JSONDecoder().decode(CodexThemeSourcesFile.self, from: data),
              file.sources.isEmpty == false
        else { return CodexThemeSource.builtins }
        return file.sources
    }

    func persistSources() throws {
        try CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = CodexThemeSourcesFile(schemaVersion: 1, sources: self.sources)
        try CodexPaths.writeSecureFile(try encoder.encode(file), to: CodexPaths.themeSourcesURL)
    }

    func setSource(id: String, enabled: Bool) {
        guard let index = self.sources.firstIndex(where: { $0.id == id }) else { return }
        self.sources[index].enabled = enabled
        try? self.persistSources()
    }

    func addSource(name: String, baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed.isEmpty == false else { return }
        let id = CodexProfileService.slugify(name, existing: Set(self.sources.map(\.id)))
        self.sources.append(
            CodexThemeSource(id: id, name: name, baseURL: trimmed, enabled: true)
        )
        try? self.persistSources()
    }

    // MARK: 状态持久化

    private static func readState() -> CodexThemeInstallState {
        guard let data = try? Data(contentsOf: CodexPaths.themeStateURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CodexThemeInstallState.self, from: data)) ?? .empty
    }

    private func persistState() throws {
        try CodexPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(try encoder.encode(self.state), to: CodexPaths.themeStateURL)
    }

    // MARK: 市场

    /// 逐个源拉取索引并合并。单个源失败不影响其它源，
    /// 失败原因汇总在 `lastRefreshIssues` 里，避免一个挂掉的库把整个市场拖垮。
    func refreshMarket() async throws {
        self.isLoadingMarket = true
        defer { self.isLoadingMarket = false }

        var merged: [CodexThemeListing] = []
        var issues: [String] = []

        for source in self.sources where source.enabled {
            do {
                let themes = try await self.fetchIndex(source: source)
                merged.append(contentsOf: themes)
            } catch {
                issues.append("\(source.name)：\(error.localizedDescription)")
            }
        }

        merged.append(contentsOf: self.localListings())

        self.listings = merged
        self.lastRefreshIssues = issues

        if merged.isEmpty, issues.isEmpty == false {
            throw CodexThemeError.downloadFailed(issues.joined(separator: "；"))
        }
    }

    private func fetchIndex(source: CodexThemeSource) async throws -> [CodexThemeListing] {
        if source.format == .dreamSkinAPI {
            return try await self.fetchDreamSkinIndex(source: source)
        }

        guard let url = URL(string: "\(source.baseURL)/index.json") else {
            throw CodexThemeError.badIndex
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CodexThemeError.downloadFailed(
                "index.json HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        let decoder = JSONDecoder()

        // 格式一：CodexPlusPlus-Themes（themes[] + 相对路径）
        if let index = try? decoder.decode(CodexThemeMarketIndex.self, from: data) {
            return index.themes.map { listing in
                var copy = listing
                copy.sourceBaseURL = source.baseURL
                copy.sourceName = source.name
                return copy
            }
        }

        // 格式二：awesome-codex-skins（skins[] + .codexskin 压缩包）
        if let catalog = try? decoder.decode(CodexSkinPackCatalog.self, from: data) {
            return catalog.skins.map { entry in
                CodexThemeListing(
                    id: entry.id,
                    name: entry.name,
                    version: entry.version,
                    author: entry.author,
                    description: entry.description,
                    license: entry.license,
                    sourceUrl: catalog.source,
                    tags: entry.tags,
                    theme: entry.pack,
                    image: nil,
                    preview: entry.preview,
                    sourceBaseURL: source.baseURL,
                    sourceName: source.name,
                    isPack: true,
                    declaredSha256: entry.sha256
                )
            }
        }

        throw CodexThemeError.badIndex
    }

    /// dreamskin.cc 每页上限 24，按 offset 翻页。
    /// 默认只取前 `dreamSkinPageLimit` 页（约 120 套）——总量 400+，
    /// 全量拉取要 18 次请求，对菜单和预览页都是负担，需要更多可在设置里调。
    static var dreamSkinPageLimit = 5

    private func fetchDreamSkinIndex(source: CodexThemeSource) async throws -> [CodexThemeListing] {
        var collected: [CodexThemeListing] = []
        var offset = 0
        let pageSize = 24

        for _ in 0..<Self.dreamSkinPageLimit {
            guard let url = URL(string: "\(source.baseURL)/v1/themes?limit=\(pageSize)&offset=\(offset)") else {
                break
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CodexThemeError.downloadFailed(
                    "dreamskin HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                )
            }
            guard let page = try? JSONDecoder().decode(CodexDreamSkinPage.self, from: data) else {
                throw CodexThemeError.badIndex
            }

            for item in page.items {
                collected.append(
                    CodexThemeListing(
                        id: item.themeId ?? item.id,
                        name: item.name,
                        version: item.version ?? "1.0.0",
                        author: item.authorDisplayName,
                        description: item.downloadCount.map { "下载 \($0) 次" },
                        license: item.license,
                        sourceUrl: "https://dreamskin.cc/gallery",
                        tags: item.displayMeta?.appearance.map { [$0] },
                        theme: "/v1/themes/\(item.id)/download",
                        image: nil,
                        preview: "/v1/themes/\(item.id)/preview/thumbnail",
                        sourceBaseURL: source.baseURL,
                        sourceName: source.name,
                        isPack: true,
                        declaredSha256: item.packageSha256,
                        inlineColors: item.displayMeta?.colors,
                        inlineAppearance: item.displayMeta?.appearance
                    )
                )
            }

            offset += pageSize
            if offset >= page.total || page.items.isEmpty { break }
        }
        return collected
    }

    /// 本地皮肤库：`~/.codexbar/themes-local/<id>/{theme.json,image.*}`。
    /// 用来收纳市场上没有的主题——例如从 Codex++ 里导出的自定义皮肤。
    func localListings() -> [CodexThemeListing] {
        let root = CodexPaths.localThemesRootURL
        guard let entries = try? self.fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { directory -> CodexThemeListing? in
            let themeURL = directory.appendingPathComponent("theme.json")
            guard let data = try? Data(contentsOf: themeURL),
                  let definition = try? JSONDecoder().decode(CodexThemeDefinition.self, from: data)
            else { return nil }

            let id = definition.id ?? directory.lastPathComponent
            let hasImage = ["image.png", "image.jpg", "image.jpeg", "image.webp"]
                .contains { self.fileManager.fileExists(
                    atPath: directory.appendingPathComponent($0).path
                ) }

            return CodexThemeListing(
                id: id,
                name: definition.name ?? id,
                version: "local",
                author: "本地",
                description: definition.tagline,
                license: nil,
                sourceUrl: directory.path,
                tags: ["本地"],
                theme: "theme.json",
                image: hasImage ? "image.png" : nil,
                preview: nil,
                sourceBaseURL: Self.localSourceMarker,
                sourceName: "本地皮肤库"
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// 从任意目录导入一套主题到本地库（复制，不移动原文件）。
    @discardableResult
    func importLocalTheme(from directory: URL) throws -> String {
        let themeURL = directory.appendingPathComponent("theme.json")
        let data = try Data(contentsOf: themeURL)
        let definition = try JSONDecoder().decode(CodexThemeDefinition.self, from: data)
        let id = definition.id ?? directory.lastPathComponent

        let destination = CodexPaths.localThemesRootURL.appendingPathComponent(id, isDirectory: true)
        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appendingPathComponent("theme.json"), options: .atomic)

        for candidate in ["image.png", "image.jpg", "image.jpeg", "image.webp", "background.png"] {
            let source = directory.appendingPathComponent(candidate)
            guard self.fileManager.fileExists(atPath: source.path) else { continue }
            let ext = (candidate as NSString).pathExtension
            let target = destination.appendingPathComponent("image.\(ext)")
            try? self.fileManager.removeItem(at: target)
            try self.fileManager.copyItem(at: source, to: target)
            break
        }
        return id
    }

    func installedTheme(id: String) -> CodexInstalledTheme? {
        self.state.installed.first { $0.id == id }
    }

    func themeDirectory(id: String) -> URL {
        CodexPaths.themesRootURL.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: 安装

    @discardableResult
    func install(_ listing: CodexThemeListing) async throws -> CodexInstalledTheme {
        let directory = self.themeDirectory(id: listing.id)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = listing.sourceBaseURL ?? Self.marketBaseURL

        // 本地库的主题直接从磁盘复制，不走网络
        if base == Self.localSourceMarker {
            return try self.installLocal(listing)
        }

        // 列表里已内嵌配色（dreamskin.cc）：先落地配色，壁纸尽力而为。
        // 这样即使安装包很大、下载超时，主题的配色部分依然立即可用。
        if let colors = listing.inlineColors {
            return try await self.installInline(listing, colors: colors, base: base)
        }

        // awesome-codex-skins 的 .codexskin 压缩包
        if listing.isPack == true {
            return try await self.installPack(listing, base: base)
        }

        let themeData = try await self.fetch(relativePath: listing.theme, base: base)
        let themeDigest = Self.sha256Hex(themeData)

        // TOFU：同版本重装时，摘要必须与首次安装一致
        if let existing = self.installedTheme(id: listing.id),
           existing.version == listing.version,
           existing.themeSha256 != themeDigest {
            throw CodexThemeError.integrityMismatch(listing.id)
        }

        try themeData.write(to: directory.appendingPathComponent("theme.json"), options: .atomic)

        var imageDigest: String?
        var hasImage = false
        if let imagePath = listing.image, imagePath.isEmpty == false {
            if let imageData = try? await self.fetch(relativePath: imagePath, base: base) {
                imageDigest = Self.sha256Hex(imageData)
                let ext = (imagePath as NSString).pathExtension.isEmpty
                    ? "png" : (imagePath as NSString).pathExtension
                try imageData.write(
                    to: directory.appendingPathComponent("image.\(ext)"),
                    options: .atomic
                )
                hasImage = true
            }
        }

        let record = CodexInstalledTheme(
            id: listing.id,
            name: listing.name,
            version: listing.version,
            installedAt: Date(),
            themeSha256: themeDigest,
            imageSha256: imageDigest,
            hasImage: hasImage
        )
        self.state.installed.removeAll { $0.id == listing.id }
        self.state.installed.append(record)
        try self.persistState()
        return record
    }

    /// 安装本地库中的主题：从 `themes-local/<id>/` 复制到 `themes/<id>/`。
    private func installLocal(_ listing: CodexThemeListing) throws -> CodexInstalledTheme {
        let source = CodexPaths.localThemesRootURL.appendingPathComponent(listing.id, isDirectory: true)
        let destination = self.themeDirectory(id: listing.id)
        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let themeData = try Data(contentsOf: source.appendingPathComponent("theme.json"))
        try themeData.write(to: destination.appendingPathComponent("theme.json"), options: .atomic)

        var imageDigest: String?
        var hasImage = false
        for candidate in ["image.png", "image.jpg", "image.jpeg", "image.webp"] {
            let imageURL = source.appendingPathComponent(candidate)
            guard let imageData = try? Data(contentsOf: imageURL) else { continue }
            try imageData.write(to: destination.appendingPathComponent(candidate), options: .atomic)
            imageDigest = Self.sha256Hex(imageData)
            hasImage = true
            break
        }

        let record = CodexInstalledTheme(
            id: listing.id,
            name: listing.name,
            version: listing.version,
            installedAt: Date(),
            themeSha256: Self.sha256Hex(themeData),
            imageSha256: imageDigest,
            hasImage: hasImage
        )
        self.state.installed.removeAll { $0.id == listing.id }
        self.state.installed.append(record)
        try self.persistState()
        return record
    }

    /// 安装 `.codexskin` 压缩包（zip）。上游声明了 sha256，这里做**强校验**——
    /// 与另一个库的 TOFU 不同，这里摘要不符直接拒绝安装。
    private func installPack(_ listing: CodexThemeListing, base: String) async throws -> CodexInstalledTheme {
        let packData = try await self.fetch(relativePath: listing.theme, base: base)

        if let declared = listing.declaredSha256, declared.isEmpty == false {
            let actual = Self.sha256Hex(packData)
            // 目录里的摘要可能是截断值，按前缀比对
            guard actual.hasPrefix(declared.lowercased()) || actual == declared.lowercased() else {
                throw CodexThemeError.integrityMismatch(listing.id)
            }
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-pack-\(listing.id)", isDirectory: true)
        try? self.fileManager.removeItem(at: staging)
        try self.fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? self.fileManager.removeItem(at: staging) }

        let packURL = staging.appendingPathComponent("pack.zip")
        try packData.write(to: packURL, options: .atomic)

        // Swift 标准库没有 zip 支持，借用系统 unzip；-o 覆盖，-qq 静默
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", packURL.path, "-d", staging.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw CodexThemeError.downloadFailed("解压 \(listing.id) 失败")
        }

        // 包内可能有一层顶层目录
        var contentRoot = staging
        if self.fileManager.fileExists(atPath: staging.appendingPathComponent("theme.json").path) == false,
           let entries = try? self.fileManager.contentsOfDirectory(
               at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
           ) {
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if self.fileManager.fileExists(atPath: entry.appendingPathComponent("theme.json").path) {
                    contentRoot = entry
                    break
                }
            }
        }

        let destination = self.themeDirectory(id: listing.id)
        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let themeData = try Data(contentsOf: contentRoot.appendingPathComponent("theme.json"))
        try themeData.write(to: destination.appendingPathComponent("theme.json"), options: .atomic)

        var imageDigest: String?
        var hasImage = false
        let imageNames = ["image.png", "image.jpg", "image.jpeg", "image.webp",
                          "background.png", "background.jpg", "wallpaper.png", "wallpaper.jpg"]
        for candidate in imageNames {
            let source = contentRoot.appendingPathComponent(candidate)
            guard let imageData = try? Data(contentsOf: source) else { continue }
            let ext = (candidate as NSString).pathExtension
            try imageData.write(to: destination.appendingPathComponent("image.\(ext)"), options: .atomic)
            imageDigest = Self.sha256Hex(imageData)
            hasImage = true
            break
        }

        let record = CodexInstalledTheme(
            id: listing.id,
            name: listing.name,
            version: listing.version,
            installedAt: Date(),
            themeSha256: Self.sha256Hex(themeData),
            imageSha256: imageDigest,
            hasImage: hasImage
        )
        self.state.installed.removeAll { $0.id == listing.id }
        self.state.installed.append(record)
        try self.persistState()
        return record
    }

    /// 内嵌配色的安装：立刻写出 theme.json，再尝试下载壁纸包。
    /// 壁纸失败不算安装失败——配色本身已经可用。
    private func installInline(
        _ listing: CodexThemeListing,
        colors: CodexThemeDefinition.Colors,
        base: String
    ) async throws -> CodexInstalledTheme {
        let destination = self.themeDirectory(id: listing.id)
        try self.fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let definition = CodexThemeDefinition(
            schemaVersion: 1,
            id: listing.id,
            name: listing.name,
            brandSubtitle: nil,
            tagline: listing.description,
            colors: colors,
            image: nil,
            appearance: listing.inlineAppearance
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let themeData = try encoder.encode(definition)
        try themeData.write(to: destination.appendingPathComponent("theme.json"), options: .atomic)

        var imageDigest: String?
        var hasImage = false

        // 壁纸在安装包里。包动辄数 MB，网络差时很慢，因此设为尽力而为。
        if let packData = try? await self.fetch(relativePath: listing.theme, base: base) {
            if let declared = listing.declaredSha256, declared.isEmpty == false {
                let actual = Self.sha256Hex(packData)
                guard actual.hasPrefix(declared.lowercased()) || actual == declared.lowercased() else {
                    throw CodexThemeError.integrityMismatch(listing.id)
                }
            }
            if let extracted = try? self.extractImage(from: packData, id: listing.id) {
                let target = destination.appendingPathComponent("image.\(extracted.ext)")
                try? extracted.data.write(to: target, options: .atomic)
                imageDigest = Self.sha256Hex(extracted.data)
                hasImage = true
            }
        }

        let record = CodexInstalledTheme(
            id: listing.id,
            name: listing.name,
            version: listing.version,
            installedAt: Date(),
            themeSha256: Self.sha256Hex(themeData),
            imageSha256: imageDigest,
            hasImage: hasImage
        )
        self.state.installed.removeAll { $0.id == listing.id }
        self.state.installed.append(record)
        try self.persistState()
        return record
    }

    /// 从 zip 包里取出第一张壁纸图。
    private func extractImage(from packData: Data, id: String) throws -> (data: Data, ext: String) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-inline-\(id)", isDirectory: true)
        try? self.fileManager.removeItem(at: staging)
        try self.fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? self.fileManager.removeItem(at: staging) }

        let packURL = staging.appendingPathComponent("pack.zip")
        try packData.write(to: packURL, options: .atomic)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", packURL.path, "-d", staging.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw CodexThemeError.downloadFailed("解压失败")
        }

        guard let walker = self.fileManager.enumerator(
            at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { throw CodexThemeError.downloadFailed("包内无资源") }

        var best: (URL, Int)?
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp"].contains(ext) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // 取最大的一张，缩略图/图标通常远小于壁纸
            if best == nil || size > best!.1 { best = (url, size) }
        }
        guard let picked = best else { throw CodexThemeError.downloadFailed("包内无图片") }
        return (try Data(contentsOf: picked.0), picked.0.pathExtension.lowercased())
    }

    func uninstall(id: String) throws {
        let directory = self.themeDirectory(id: id)
        var trashed: NSURL?
        try? self.fileManager.trashItem(at: directory, resultingItemURL: &trashed)
        self.state.installed.removeAll { $0.id == id }
        if self.state.appliedThemeID == id { self.state.appliedThemeID = nil }
        try self.persistState()
    }

    private func fetch(relativePath: String, base: String) async throws -> Data {
        if base == Self.localSourceMarker {
            throw CodexThemeError.downloadFailed("本地主题无需下载")
        }
        guard let url = URL(string: "\(base)/\(relativePath)") else {
            throw CodexThemeError.downloadFailed(relativePath)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CodexThemeError.downloadFailed(
                "\(relativePath) HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        return data
    }

    func loadDefinition(id: String) throws -> CodexThemeDefinition {
        let url = self.themeDirectory(id: id).appendingPathComponent("theme.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CodexThemeDefinition.self, from: data)
    }

    // MARK: 应用（原生配色，写 config.toml）

    /// 把主题配色写进 `~/.codex/config.toml` 的 `[desktop.appearance*ChromeTheme]`。
    /// 只替换这几张表，文件其余部分逐字节保留；写入前先备份。
    func applyNativeColors(themeID: String) throws {
        let definition = try self.loadDefinition(id: themeID)
        let configURL = CodexPaths.configTomlURL
        guard let original = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw CodexThemeError.configMissing
        }

        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.bak-codexbar-theme")
        try? Data(original.utf8).write(to: backupURL, options: .atomic)

        let colors = definition.colors

        var body: [String] = []
        if let accent = Self.normalizedHex(colors.accent) { body.append("accent = \"\(accent)\"") }
        if let ink = Self.normalizedHex(colors.text) { body.append("ink = \"\(ink)\"") }
        if let surface = Self.normalizedHex(colors.background) { body.append("surface = \"\(surface)\"") }
        // 刻意不写 opaqueWindows：把窗口设为半透明后，网页盖不到的窗口顶端
        // 会露出系统底层材质，形成一条发亮的窄带。保持应用默认即可。

        var semantic: [String] = []
        if let highlight = Self.normalizedHex(colors.highlight) { semantic.append("skill = \"\(highlight)\"") }
        if let secondary = Self.normalizedHex(colors.secondary) { semantic.append("diffAdded = \"\(secondary)\"") }
        if let accentAlt = Self.normalizedHex(colors.accentAlt) { semantic.append("diffRemoved = \"\(accentAlt)\"") }

        // 明暗两张表都写。
        // theme.json 里的 `appearance` 说的是主题自身的风格倾向，
        // 而 Codex 读哪张表取决于**应用当前的外观模式**——两者并不对应。
        // 早先只按 appearance 写一张表，导致深色模式下应用浅色主题毫无反应。
        var updated = original
        for tableName in ["desktop.appearanceLightChromeTheme", "desktop.appearanceDarkChromeTheme"] {
            updated = Self.replaceTable(in: updated, table: tableName, body: body)
            if semantic.isEmpty == false {
                updated = Self.replaceTable(in: updated, table: "\(tableName).semanticColors", body: semantic)
            }
        }

        try CodexPaths.writeSecureFile(Data(updated.utf8), to: configURL)

        self.state.appliedThemeID = themeID
        try self.persistState()
    }

    /// 撤销：删掉本服务写入的主题表，恢复 Codex 默认外观。
    func revertNativeColors() throws {
        let configURL = CodexPaths.configTomlURL
        guard let original = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw CodexThemeError.configMissing
        }
        var updated = original
        for table in [
            "desktop.appearanceLightChromeTheme.semanticColors",
            "desktop.appearanceDarkChromeTheme.semanticColors",
            "desktop.appearanceLightChromeTheme",
            "desktop.appearanceDarkChromeTheme",
        ] {
            updated = Self.removeTable(in: updated, table: table)
        }
        try CodexPaths.writeSecureFile(Data(updated.utf8), to: configURL)
        self.state.appliedThemeID = nil
        try self.persistState()
    }

    // MARK: TOML 外科手术

    /// 定位一张 TOML 表的行区间：从 `[table]` 头行起，到下一个表头（或文件末尾）止。
    static func tableRange(in lines: [String], table: String) -> Range<Int>? {
        let header = "[\(table)]"
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == header
        }) else { return nil }

        var end = lines.count
        var index = start + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                end = index
                break
            }
            index += 1
        }
        return start..<end
    }

    /// 合并式写入：只覆盖 `body` 里出现的键，表内其它键（例如用户自己设的 `contrast`）
    /// 原样保留。整表替换会悄悄吃掉用户设置，因此这里坚持做合并。
    /// 子表（`[x.y.fonts]` 之类）位于本表区间之外，天然不受影响。
    static func replaceTable(in content: String, table: String, body: [String]) -> String {
        var lines = content.components(separatedBy: "\n")
        let incomingKeys = Set(body.compactMap { self.tomlKey(of: $0) })

        guard let range = self.tableRange(in: lines, table: table) else {
            if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false { lines.append("") }
            lines.append(contentsOf: ["[\(table)]"] + body + [""])
            return lines.joined(separator: "\n")
        }

        // 保留原表中不被本次覆盖的键值行（注释与空行一并保留）
        var preserved: [String] = []
        for line in lines[(range.lowerBound + 1)..<range.upperBound] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let key = self.tomlKey(of: line), incomingKeys.contains(key) { continue }
            preserved.append(line)
        }

        lines.replaceSubrange(range, with: ["[\(table)]"] + body + preserved + [""])
        return lines.joined(separator: "\n")
    }

    /// 从一行 `key = value` 中取出键名；不是键值行则返回 nil。
    static func tomlKey(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false, trimmed.hasPrefix("#") == false else { return nil }
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    static func removeTable(in content: String, table: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let range = self.tableRange(in: lines, table: table) else { return content }
        lines.removeSubrange(range)
        return lines.joined(separator: "\n")
    }

    // MARK: 小工具

    static func normalizedHex(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
            return nil
        }
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard hex.count == 3 || hex.count == 6 || hex.count == 8,
              hex.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "#\(hex.lowercased())"
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
