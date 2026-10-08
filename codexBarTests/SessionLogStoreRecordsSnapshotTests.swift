import Foundation
import XCTest

final class SessionLogStoreRecordsSnapshotTests: CodexBarTestCase {
    @MainActor
    func testRecordsPageImmediatelyUsesPersistedCache() async throws {
        let home = try self.makeCodexHome()
        let first = self.makeStore(home: home)
        try self.writeFastSession(directory: home.appendingPathComponent(".codex/sessions"), fileName: "cached.jsonl", id: "cached", timestamp: "2026-04-21T08:00:00Z", model: "gpt-6.1-sol", inputTokens: 100, cachedInputTokens: 20, outputTokens: 10)
        _ = try await first.loadRecordsSourceSnapshot(refreshMode: .incremental)
        let relaunched = self.makeStore(home: home)
        let viewModel = SettingsRecordsViewModel(service: RecordsSnapshotService(sourceLoader: relaunched))
        XCTAssertEqual(viewModel.snapshot?.sessions.map(\.sessionID), ["cached"])
        XCTAssertEqual(viewModel.snapshot?.models.map(\.modelID), ["gpt-6.1-sol"])
        XCTAssertFalse(viewModel.shouldShowSkeleton)
        // 获取首屏快照无需重新遍历日志目录。
        try FileManager.default.removeItem(at: home.appendingPathComponent(".codex/sessions"))
        XCTAssertEqual(relaunched.cachedRecordsSourceSnapshot()?.sessions.map(\.sessionID), ["cached"])
    }

    func testHistoricalModelsRefreshSessionCacheIncludesNewSessionModel() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: true), ["gpt-5.5"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 50,
            cachedInputTokens: 0,
            outputTokens: 10
        )

        XCTAssertEqual(store.historicalModels(refreshSessionCache: false), ["gpt-5.5"])
        XCTAssertEqual(
            store.historicalModels(refreshSessionCache: true),
            ["google/gemini-2.5-pro", "gpt-5.5"]
        )
    }

    func testReduceBillableEventsRefreshSessionCacheRebuildsLedgerForNewSessionFiles() throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home) { _, usage, _ in
            Double(usage.totalTokens)
        }

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha"]
        )

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: false),
            ["alpha"]
        )
        XCTAssertEqual(
            self.billableSessionIDs(from: store, refreshSessionCache: true),
            ["alpha", "beta"]
        )
    }

    func testRecordsSnapshotMergesResumedSegmentsAndKeepsLatestMetadata() async throws {
        let home = try self.makeCodexHome()
        let directory = home.appendingPathComponent(".codex/sessions")
        try self.writeFastSession(directory: directory, fileName: "original.jsonl", id: "resumed", timestamp: "2026-04-20T08:00:00Z", model: "gpt-5.5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 10)
        try self.writeFastSession(directory: directory, fileName: "resumed.jsonl", id: "resumed", timestamp: "2026-04-21T08:00:00Z", model: "gpt-6.1-sol", inputTokens: 30, cachedInputTokens: 10, outputTokens: 10)
        let latestActivity = Date(timeIntervalSinceNow: 60)
        try FileManager.default.setAttributes([.modificationDate: latestActivity], ofItemAtPath: directory.appendingPathComponent("resumed.jsonl").path)

        let store = self.makeStore(home: home)
        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        let record = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(record.totalTokens, 150)
        XCTAssertEqual(record.modelID, "gpt-6.1-sol")
        XCTAssertEqual(record.startedAt, ISO8601Parsing.parse("2026-04-20T08:00:00Z"))
        XCTAssertEqual(record.lastActivityAt.timeIntervalSince1970, latestActivity.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(record.isArchived)
        XCTAssertEqual(self.makeStore(home: home).cachedRecordsSourceSnapshot()?.sessions.first?.totalTokens, 150)
        let total = store.reduceBillableEvents(into: 0, refreshSessionCache: false) { $0 += $1.usage.totalTokens }
        XCTAssertEqual(total, record.totalTokens)
    }

    func testLoadRecordsSourceSnapshotCapturesWarnings() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "valid.jsonl",
            id: "valid",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let incompleteURL = codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("incomplete.jsonl")
        let incompleteContent = [
            #"{"payload":{"type":"session_meta","id":"broken","timestamp":"2026-04-21T09:00:00Z"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":90,"cached_input_tokens":10,"output_tokens":10}}}"#,
        ].joined(separator: "\n") + "\n"
        try incompleteContent.write(to: incompleteURL, atomically: true, encoding: .utf8)

        let snapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)

        XCTAssertEqual(snapshot.refreshMode, .incremental)
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["valid"])
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].sessionFilePath.hasSuffix("/incomplete.jsonl"))
        XCTAssertEqual(snapshot.warnings[0].kind, .incompleteSessionRecord)
    }

    func testRebuildAllReturnsFreshRecordsSourceSnapshot() async throws {
        let home = try self.makeCodexHome()
        let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
        let store = self.makeStore(home: home)

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            fileName: "alpha.jsonl",
            id: "alpha",
            timestamp: "2026-04-21T08:00:00Z",
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 20
        )

        let firstSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .incremental)
        XCTAssertEqual(firstSnapshot.sessions.map(\.sessionID), ["alpha"])

        try self.writeFastSession(
            directory: codexRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            fileName: "beta.jsonl",
            id: "beta",
            timestamp: "2026-04-21T09:00:00Z",
            model: "google/gemini-2.5-pro",
            inputTokens: 30,
            cachedInputTokens: 10,
            outputTokens: 10
        )

        let rebuiltSnapshot = try await store.loadRecordsSourceSnapshot(refreshMode: .rebuildAll)

        XCTAssertEqual(rebuiltSnapshot.refreshMode, .rebuildAll)
        XCTAssertEqual(rebuiltSnapshot.sessions.map(\.sessionID), ["beta", "alpha"])
        XCTAssertEqual(
            rebuiltSnapshot.sessions.map(\.modelID),
            ["google/gemini-2.5-pro", "gpt-5.5"]
        )
    }

    private func billableSessionIDs(from store: SessionLogStore, refreshSessionCache: Bool) -> [String] {
        store.reduceBillableEvents(into: Set<String>(), refreshSessionCache: refreshSessionCache) { partialResult, event in
            partialResult.insert(event.sessionID)
        }
        .sorted()
    }

    private func makeCodexHome() throws -> URL {
        let home = try XCTUnwrap(self.temporaryHomeURL())
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func temporaryHomeURL() -> URL? {
        let home = ProcessInfo.processInfo.environment["CODEXBAR_HOME"]
        guard let home, home.isEmpty == false else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func makeStore(
        home: URL,
        billableCostCalculator: @escaping (String, SessionLogStore.Usage, SessionLogStore.Usage) -> Double? = { model, usage, sessionUsage in
            LocalCostPricing.costUSD(model: model, usage: usage, sessionUsage: sessionUsage)
        }
    ) -> SessionLogStore {
        SessionLogStore(
            codexRootURL: home.appendingPathComponent(".codex", isDirectory: true),
            persistedCacheURL: home.appendingPathComponent(".codexbar/test-records-session-cache.json"),
            persistedUsageLedgerURL: home.appendingPathComponent(".codexbar/test-records-ledger.json"),
            billableCostCalculator: billableCostCalculator
        )
    }

    private func writeFastSession(
        directory: URL,
        fileName: String,
        id: String,
        timestamp: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) throws {
        let fileURL = directory.appendingPathComponent(fileName)
        let content = [
            #"{"payload":{"type":"session_meta","id":"\#(id)","timestamp":"\#(timestamp)"}}"#,
            #"{"payload":{"type":"turn_context","model":"\#(model)"}}"#,
            #"{"payload":{"type":"event_msg","kind":"token_count","total_token_usage":{"input_tokens":\#(inputTokens),"cached_input_tokens":\#(cachedInputTokens),"output_tokens":\#(outputTokens)}}}"#,
        ].joined(separator: "\n") + "\n"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
