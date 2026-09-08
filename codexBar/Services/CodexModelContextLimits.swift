import Foundation

/// 使用本机 Codex 模型目录估计有效容量，实际运行上报始终优先。
struct CodexModelContextLimits: Equatable {
    let maximum: Int
    let effectivePercent: Int

    func estimatedWindow(configured: Int) -> Int? {
        guard configured > 0, maximum > 0, (1...100).contains(effectivePercent) else { return nil }
        let capped = min(configured, maximum)
        return capped / 100 * effectivePercent + capped % 100 * effectivePercent / 100
    }

    static func read(model: String) -> Self? {
        let path = CodexPaths.codexRoot.appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return decode(data: data, model: model)
    }

    static func decode(data: Data, model: String) -> Self? {
        struct Entry: Decodable {
            let slug: String
            let max_context_window: Int?
            let effective_context_window_percent: Int?
        }
        struct Catalog: Decodable { let models: [Entry] }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              let entry = catalog.models.first(where: { $0.slug == model }),
              let maximum = entry.max_context_window, maximum > 0,
              let percent = entry.effective_context_window_percent, (1...100).contains(percent)
        else { return nil }
        return Self(maximum: maximum, effectivePercent: percent)
    }
}
