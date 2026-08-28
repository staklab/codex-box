import Foundation
import SQLite3

private nonisolated(unsafe) let threadContextSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

/// 从 Codex 自己的只读运行记录中读取某个会话最近一次上报的实际有效上下文窗口。
///
/// 这里不启动 app-server，也不修改任何 Codex 文件。先通过 `state_*.sqlite` 精确取得
/// rollout 路径，再只读取 JSONL 文件尾部，避免会话多或日志大时阻塞菜单。
struct CodexThreadContextWindowReader: Sendable {
    private let stateDBPath: String
    private let maximumTailBytes: UInt64

    nonisolated init(stateDBURL: URL, maximumTailBytes: UInt64 = 4 * 1_024 * 1_024) {
        self.stateDBPath = stateDBURL.path
        self.maximumTailBytes = maximumTailBytes
    }

    nonisolated func latestEffectiveContextWindow(threadID: String) -> Int? {
        guard let rolloutPath = self.rolloutPath(threadID: threadID) else { return nil }
        return Self.latestEffectiveContextWindow(
            inRolloutAt: URL(fileURLWithPath: rolloutPath),
            maximumTailBytes: self.maximumTailBytes
        )
    }

    private nonisolated func rolloutPath(threadID: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            self.stateDBPath,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard threadID.withCString({ pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, threadContextSQLiteTransient)
        }) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else { return nil }

        return String(cString: value)
    }

    private nonisolated static func latestEffectiveContextWindow(
        inRolloutAt url: URL,
        maximumTailBytes: UInt64
    ) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let startOffset = fileSize > maximumTailBytes ? fileSize - maximumTailBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.readToEnd() else { return nil }
            return Self.latestEffectiveContextWindow(inRolloutTail: data)
        } catch {
            return nil
        }
    }

    nonisolated static func latestEffectiveContextWindow(inRolloutTail data: Data) -> Int? {
        for line in data.split(separator: 0x0A).reversed() {
            guard line.contains(Self.tokenCountNeedle),
                  line.contains(Self.contextWindowNeedle),
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let contextWindow = info["model_context_window"] as? Int,
                  contextWindow > 0
            else { continue }
            return contextWindow
        }
        return nil
    }

    private nonisolated static let tokenCountNeedle = Data("\"token_count\"".utf8)
    private nonisolated static let contextWindowNeedle = Data("\"model_context_window\"".utf8)
}
