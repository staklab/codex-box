import Foundation

enum RecordsRefreshMode: Equatable, Sendable {
    case incremental
    case rebuildAll
}

enum RecordsSnapshotWarningKind: String, Codable, Equatable, Sendable {
    case unreadableSessionFile
    case incompleteSessionRecord
}

struct RecordsSnapshotWarning: Codable, Equatable, Identifiable, Sendable {
    let sessionFilePath: String
    let kind: RecordsSnapshotWarningKind
    let message: String

    var id: String {
        "\(self.kind.rawValue)|\(self.sessionFilePath)|\(self.message)"
    }
}

struct HistoricalModelRecord: Codable, Equatable, Identifiable, Sendable {
    let modelID: String
    let sessionCount: Int
    let lastSeenAt: Date

    var id: String { self.modelID }
}

struct HistoricalSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let sessionID: String
    let modelID: String
    let startedAt: Date
    let lastActivityAt: Date
    let isArchived: Bool
    let totalTokens: Int

    var id: String { self.sessionID }
}

struct RecordsSourceSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

struct RecordsSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let refreshMode: RecordsRefreshMode
    let models: [HistoricalModelRecord]
    let sessions: [HistoricalSessionRecord]
    let warnings: [RecordsSnapshotWarning]
}

protocol RecordsSourceSnapshotLoading: Sendable {
    func cachedRecordsSourceSnapshot() -> RecordsSourceSnapshot?
    func loadRecordsSourceSnapshot(refreshMode: RecordsRefreshMode) async throws -> RecordsSourceSnapshot
}

extension RecordsSourceSnapshotLoading {
    func cachedRecordsSourceSnapshot() -> RecordsSourceSnapshot? { nil }
}

protocol RecordsSnapshotServing: Sendable {
    func cachedSnapshot() -> RecordsSnapshot?
    func loadCurrent() async throws -> RecordsSnapshot
    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot
}

extension RecordsSnapshotServing {
    func cachedSnapshot() -> RecordsSnapshot? { nil }
}

enum RecordsSnapshotServiceError: LocalizedError, Equatable {
    case requestSuperseded
    case timedOut(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestSuperseded:
            return "Records request was superseded by a newer request."
        case .timedOut(let timeout):
            let seconds = String(format: "%.1f", timeout)
            return "Records refresh timed out after \(seconds) seconds."
        }
    }
}

struct RecordsSnapshotService: RecordsSnapshotServing {
    private let sourceLoader: any RecordsSourceSnapshotLoading
    private let requestCoordinator: RecordsSnapshotRequestCoordinator
    private let loadTimeout: TimeInterval

    init(
        sourceLoader: any RecordsSourceSnapshotLoading = SessionLogStore.shared,
        requestCoordinator: RecordsSnapshotRequestCoordinator = RecordsSnapshotRequestCoordinator(),
        loadTimeout: TimeInterval = 15
    ) {
        self.sourceLoader = sourceLoader
        self.requestCoordinator = requestCoordinator
        self.loadTimeout = max(0, loadTimeout)
    }

    func cachedSnapshot() -> RecordsSnapshot? {
        self.sourceLoader.cachedRecordsSourceSnapshot().map(Self.makeSnapshot(from:))
    }

    func loadCurrent() async throws -> RecordsSnapshot {
        try await self.requestCoordinator.runRequest(
            refreshMode: .incremental,
            timeout: self.loadTimeout,
            sourceLoader: self.sourceLoader,
            makeSnapshot: Self.makeSnapshot(from:)
        )
    }

    func refreshAll(timeout: TimeInterval) async throws -> RecordsSnapshot {
        try await self.requestCoordinator.runRequest(
            refreshMode: .rebuildAll,
            timeout: max(0, timeout),
            sourceLoader: self.sourceLoader,
            makeSnapshot: Self.makeSnapshot(from:)
        )
    }

    nonisolated private static func makeSnapshot(from sourceSnapshot: RecordsSourceSnapshot) -> RecordsSnapshot {
        RecordsSnapshot(
            generatedAt: sourceSnapshot.generatedAt,
            refreshMode: sourceSnapshot.refreshMode,
            models: Self.models(from: sourceSnapshot.sessions),
            sessions: sourceSnapshot.sessions.sorted(by: Self.shouldSortSessionsBefore),
            warnings: sourceSnapshot.warnings.sorted(by: Self.shouldSortWarningsBefore)
        )
    }

    nonisolated private static func models(from sessions: [HistoricalSessionRecord]) -> [HistoricalModelRecord] {
        let groupedSessions = Dictionary(grouping: sessions, by: \.modelID)
        return groupedSessions.map { modelID, groupedRecords in
            HistoricalModelRecord(
                modelID: modelID,
                sessionCount: groupedRecords.count,
                lastSeenAt: groupedRecords.map(\.lastActivityAt).max() ?? .distantPast
            )
        }
        .sorted(by: Self.shouldSortModelsBefore)
    }

    nonisolated private static func shouldSortSessionsBefore(
        _ lhs: HistoricalSessionRecord,
        _ rhs: HistoricalSessionRecord
    ) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.sessionID < rhs.sessionID
    }

    nonisolated private static func shouldSortModelsBefore(
        _ lhs: HistoricalModelRecord,
        _ rhs: HistoricalModelRecord
    ) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt {
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        if lhs.sessionCount != rhs.sessionCount {
            return lhs.sessionCount > rhs.sessionCount
        }
        return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
    }

    nonisolated private static func shouldSortWarningsBefore(
        _ lhs: RecordsSnapshotWarning,
        _ rhs: RecordsSnapshotWarning
    ) -> Bool {
        if lhs.sessionFilePath != rhs.sessionFilePath {
            return lhs.sessionFilePath < rhs.sessionFilePath
        }
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.message < rhs.message
    }
}

actor RecordsSnapshotRequestCoordinator: Sendable {
    private var latestRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
    private var activeTask: Task<RecordsSnapshot, Error>?

    func runRequest(
        refreshMode: RecordsRefreshMode,
        timeout: TimeInterval?,
        sourceLoader: any RecordsSourceSnapshotLoading,
        makeSnapshot: @escaping @Sendable (RecordsSourceSnapshot) -> RecordsSnapshot
    ) async throws -> RecordsSnapshot {
        self.latestRequestID &+= 1
        let requestID = self.latestRequestID

        self.activeTask?.cancel()

        let task = Task<RecordsSnapshot, Error> {
            let sourceSnapshot = try await sourceLoader.loadRecordsSourceSnapshot(refreshMode: refreshMode)
            return makeSnapshot(sourceSnapshot)
        }

        self.activeRequestID = requestID
        self.activeTask = task

        do {
            let snapshot = try await self.resolve(task, timeout: timeout)
            guard self.activeRequestID == requestID else {
                throw RecordsSnapshotServiceError.requestSuperseded
            }
            self.clearActiveRequest(ifMatching: requestID)
            return snapshot
        } catch {
            if error is CancellationError {
                if self.activeRequestID == requestID {
                    self.clearActiveRequest(ifMatching: requestID)
                }
                throw RecordsSnapshotServiceError.requestSuperseded
            }

            if self.activeRequestID == requestID {
                self.clearActiveRequest(ifMatching: requestID)
            }
            throw error
        }
    }

    private func clearActiveRequest(ifMatching requestID: UInt64) {
        guard self.activeRequestID == requestID else { return }
        self.activeRequestID = nil
        self.activeTask = nil
    }

    private func resolve(
        _ task: Task<RecordsSnapshot, Error>,
        timeout: TimeInterval?
    ) async throws -> RecordsSnapshot {
        guard let timeout else {
            return try await task.value
        }

        let clampedTimeout = max(0, timeout)
        // 任务组退出会等待所有子任务；GCD 扫描的 continuation 不会自动响应取消。
        // 用一次性结果接收器竞争，超时后立即归还界面，不等待底层扫描退出。
        let resolution = RecordsSnapshotResolution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolution.install(continuation)
                Task { resolution.finish(await task.result) }
                let timer = Task {
                    do {
                        if clampedTimeout > 0 {
                            try await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                        }
                    } catch { return }
                    if resolution.finish(.failure(RecordsSnapshotServiceError.timedOut(timeout: clampedTimeout))) {
                        task.cancel()
                    }
                }
                resolution.installTimer(timer)
            }
        } onCancel: {
            task.cancel()
            resolution.finish(.failure(CancellationError()))
        }
    }
}

nonisolated private final class RecordsSnapshotResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<RecordsSnapshot, Error>?
    private var continuation: CheckedContinuation<RecordsSnapshot, Error>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<RecordsSnapshot, Error>) {
        self.lock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        self.lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func installTimer(_ timer: Task<Void, Never>) {
        self.lock.lock()
        let finished = self.result != nil
        if finished == false { self.timer = timer }
        self.lock.unlock()
        if finished { timer.cancel() }
    }

    @discardableResult
    func finish(_ result: Result<RecordsSnapshot, Error>) -> Bool {
        self.lock.lock()
        guard self.result == nil else { self.lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        let timer = self.timer
        self.continuation = nil
        self.timer = nil
        self.lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
        return true
    }
}
