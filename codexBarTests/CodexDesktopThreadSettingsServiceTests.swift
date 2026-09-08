import Combine
import Foundation
import XCTest

@MainActor
final class CodexDesktopThreadSettingsServiceTests: XCTestCase {
    func testMainWindowRemainsRecognizableAfterBranchNavigation() {
        func accepts(_ url: String, type: String = "page") -> Bool {
            CodexSkinInjectionService.isMainPageTarget(.init(id: "fixture", type: type,
                title: "", url: url, webSocketDebuggerUrl: "ws://127.0.0.1/test"))
        }
        XCTAssertTrue(accepts("app://-/index.html"))
        XCTAssertTrue(accepts("app://-/index.html?initialRoute=%2Flocal%2Fbranch"))
        XCTAssertTrue(accepts("app://-/index.html?initialRoute=%2Flocal%2Foriginal#fragment"))
        XCTAssertFalse(accepts("app://-/auxiliary.html?initialRoute=%2Flocal%2Fbranch"))
        XCTAssertFalse(accepts("https://example.com/index.html"))
        XCTAssertFalse(accepts("app://other/index.html"))
        XCTAssertFalse(accepts("app://-/index.html", type: "webview"))
    }

    func testActiveWindowSelectionSurvivesMenuFocusAndRejectsAmbiguity() {
        XCTAssertEqual(CodexSkinInjectionService.activeWindowIndex([(false, 10), (true, 1)]), 1)
        XCTAssertEqual(CodexSkinInjectionService.activeWindowIndex([(false, 10), (false, 20)]), 1)
        XCTAssertEqual(CodexSkinInjectionService.activeWindowIndex([(false, 30), (false, 20)]), 0)
        XCTAssertNil(CodexSkinInjectionService.activeWindowIndex([(false, 0), (false, 0)]))
        XCTAssertNil(CodexSkinInjectionService.activeWindowIndex([(false, 20), (false, 20)]))
        XCTAssertNil(CodexSkinInjectionService.activeWindowIndex([(true, 10), (true, 20)]))
        XCTAssertNil(CodexSkinInjectionService.activeWindowIndex([]))
    }

    func testNativeCDPTimeoutAndRecoveryIgnoringEvents() async throws {
        // 真实本地 WebSocket：第一条请求永不响应，第二条先发事件再发匹配响应。
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
        import socket, hashlib, base64, threading, json, struct
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        print(listener.getsockname()[1], flush=True)
        def handle(conn, index):
            with conn:
                request = b''
                while b'\r\n\r\n' not in request:
                    chunk = conn.recv(4096)
                    if not chunk: return
                    request += chunk
                headers = dict(line.split(': ', 1) for line in request.decode().split('\r\n')[1:] if ': ' in line)
                key = next(v for k,v in headers.items() if k.lower() == 'sec-websocket-key')
                accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
                conn.recv(4096)
                if index > 0:
                    for value in [{'method':'Runtime.consoleAPICalled'}, {'id':99,'result':{}}, {'id':1,'result':{'result':{'value':'recovered'}}}]:
                        data = json.dumps(value).encode()
                        conn.sendall(bytes([129,len(data)])+data)
                while conn.recv(4096): pass
        index = 0
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=handle, args=(conn,index), daemon=True).start()
            index += 1
        """#]
        let output = Pipe()
        server.standardOutput = output
        server.standardError = Pipe()
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var portData = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            portData.append(byte)
        }
        let port = try XCTUnwrap(String(data: portData, encoding: .utf8).flatMap(Int.init))
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)"))
        let injection = CodexSkinInjectionService()
        let start = Date()
        do {
            _ = try await injection.evaluate(javascript: "new Promise(() => {})", webSocketURL: url,
                awaitPromise: true, timeout: 0.3)
            XCTFail("无响应请求必须超时")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let recovered = try await injection.evaluate(javascript: "'ok'", webSocketURL: url,
            awaitPromise: true, timeout: 3)
        XCTAssertEqual(recovered as? String, "recovered")
    }

    func testRefreshRecoversAfterFailedRead() async {
        let desktop = Desktop()
        var fail = true
        let service = CodexDesktopThreadSettingsService(evaluator: { script in
            if fail { throw URLError(.timedOut) }
            return try desktop.evaluate(script)
        }, routeScript: "fixture-route")
        await service.refresh()
        XCTAssertFalse(service.canEdit)
        fail = false
        await service.refresh()
        XCTAssertEqual(service.target, .thread("first"))
        XCTAssertTrue(service.canEdit)
    }

    private final class Desktop {
        var id = "first"
        var kind = "local-thread"
        var models = ["first": "model-a", "second": "model-b"]
        var efforts = ["first": "low", "second": "high"]
        var tiers = ["first": "priority", "second": "default"]
        var writes = 0
        var forks = 0
        var active = false
        var requestedWindow: Int?
        let forkID = "10000000-0000-4000-8000-000000000001"
        var accept = true

        func evaluate(_ script: String) throws -> Any? {
            if script.contains("navigate-to-route") {
                id = forkID
                return true
            }
            if !script.contains("const payload =") {
                return try encode(["routeKind": kind, "conversationID": id, "serviceTierKnown": true, "serviceTier": tiers[id] ?? "default"])
            }
            let encoded = script.components(separatedBy: "atob('")[1].components(separatedBy: "')")[0]
            let request = try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as! [String: Any]
            let params = request["params"] as! [String: Any]
            let thread = params["threadId"] as! String
            if request["method"] as? String == "thread/fork" {
                XCTAssertEqual(params["excludeTurns"] as? Bool, true)
                forks += 1
                requestedWindow = (params["config"] as? [String: Int])?["model_context_window"]
                models[forkID] = models[thread]
                efforts[forkID] = efforts[thread]
                tiers[forkID] = tiers[thread]
                return try encode(["ok": true, "result": ["thread": ["id": forkID]]])
            }
            if request["method"] as? String == "thread/settings/update" {
                writes += 1
                if accept {
                    if let value = params["serviceTier"] as? String { tiers[thread] = value }
                    if let value = params["model"] as? String { models[thread] = value }
                    if let value = params["effort"] as? String { efforts[thread] = value }
                }
                return try encode(["ok": true, "result": [:]])
            }
            return try encode(["ok": true, "result": ["thread": ["id": thread,
                "model": models[thread]!, "reasoningEffort": efforts[thread]!, "status": ["type": active ? "active" : "idle"]]]])
        }
        func encode(_ value: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        }
    }

    func testCreatesContextBranchWithoutChangingOriginalSettings() async throws {
        let desktop = Desktop()
        var saved = false
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route",
            persistOverride: { _ in saved = true })
        await service.refresh()
        try await service.createContextWindowBranch(128000, expectedTarget: .thread("first"))
        XCTAssertEqual(desktop.forks, 1)
        XCTAssertEqual(desktop.requestedWindow, 128000)
        await service.refresh()
        XCTAssertEqual(service.target, .thread(desktop.forkID))
        XCTAssertEqual(service.preset.contextWindow, 128000)
        XCTAssertEqual(desktop.models["first"], "model-a")
        XCTAssertTrue(saved)
        await service.refresh()
        XCTAssertEqual(service.preset.contextWindow, 128000)
    }

    func testPendingForkKeepsFollowingAndSavesBeforeNavigationFailure() async throws {
        let desktop = Desktop()
        var release: CheckedContinuation<Void, Never>?
        var saved: Data?
        let service = CodexDesktopThreadSettingsService(evaluator: { script in
            if script.contains("const timeoutMs = 60000;") {
                await withCheckedContinuation { release = $0 }
            }
            return try desktop.evaluate(script)
        }, routeScript: "fixture-route", persistOverride: { saved = $0 })
        await service.refresh()
        let operation = Task { try await service.createContextWindowBranch(1_000_000, expectedTarget: .thread("first")) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        XCTAssertTrue(service.isBusy)
        desktop.id = "second"
        await service.refresh()
        XCTAssertEqual(service.target, .thread("second"), "创建期间仍应跟随其他对话")
        release?.resume()
        do { try await operation.value; XCTFail("切换页面后不得自动导航") } catch {}
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(service.branchProgress)
        XCTAssertNotNil(saved, "导航条件失败也不能丢失已经成功创建的配置")
        desktop.id = desktop.forkID
        await service.refresh()
        XCTAssertTrue(service.hasContextWindowOverride)
        XCTAssertEqual(service.displayedContextWindow, 1_000_000)
        XCTAssertNil(service.effectiveContextWindow, "配置值不能冒充实际窗口")
    }

    func testContextChangeRejectsActiveOrSwitchedThread() async {
        let desktop = Desktop()
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route",
            persistOverride: { _ in XCTFail("不应保存") })
        await service.refresh()
        desktop.active = true
        do { try await service.createContextWindowBranch(128000, expectedTarget: .thread("first")); XCTFail() } catch {}
        desktop.active = false
        desktop.id = "second"
        do { try await service.createContextWindowBranch(128000, expectedTarget: .thread("first")); XCTFail() } catch {}
        XCTAssertEqual(desktop.forks, 0)
    }

    func testPollingKeepsContextUntilCompleteAndAvoidsRedundantPublication() async {
        let desktop = Desktop()
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route",
            contextReader: { _, _, _ in 258400 })
        await service.refresh()
        var windows: [Int?] = []
        let subscription = service.$effectiveContextWindow.sink { windows.append($0) }
        await service.refresh()
        await service.refresh()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first!, 258400)
        subscription.cancel()
    }

    func testSpeedFollowsEditorAndWriteIsVerified() async throws {
        let desktop = Desktop()
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route")
        await service.refresh()
        XCTAssertEqual(service.serviceTierLabel, "Fast")
        desktop.kind = "home"
        await service.refresh()
        XCTAssertEqual(service.serviceTierLabel, "Fast")
        desktop.kind = "local-thread"
        desktop.id = "second"
        await service.refresh()
        XCTAssertEqual(service.serviceTierLabel, "标准")
        try await service.apply(model: service.preset.model, reasoningEffort: service.preset.reasoningEffort,
            serviceTier: "fast", contextWindow: service.preset.contextWindow)
        XCTAssertEqual(desktop.tiers["second"], "fast")
        XCTAssertEqual(service.serviceTierLabel, "Fast")
        desktop.tiers["second"] = "default"
        await service.refresh()
        XCTAssertEqual(service.serviceTierLabel, "标准")
    }

    func testRefreshFollowsThreadAndExternalSettings() async {
        let desktop = Desktop()
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route")
        await service.refresh()
        XCTAssertEqual(service.preset.model, "model-a")
        desktop.id = "second"
        await service.refresh()
        XCTAssertEqual(service.target, .thread("second"))
        XCTAssertEqual(service.preset.reasoningEffort, "high")
        desktop.models["second"] = "external-change"
        await service.refresh()
        XCTAssertEqual(service.preset.model, "external-change")
    }

    func testRejectsChangedTargetAndUnsupportedPage() async {
        let desktop = Desktop()
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route")
        await service.refresh()
        desktop.id = "second"
        do {
            try await service.apply(model: "new", reasoningEffort: "high", serviceTier: service.preset.serviceTier, contextWindow: service.preset.contextWindow)
            XCTFail("切换后不得写入旧对话或新对话")
        } catch {}
        XCTAssertEqual(desktop.writes, 0)
        desktop.kind = "unavailable"
        await service.refresh()
        XCTAssertFalse(service.canEdit)
    }

    func testVerifiesWriteAndRejectsFalseSuccess() async throws {
        let desktop = Desktop()
        let service = CodexDesktopThreadSettingsService(evaluator: desktop.evaluate, routeScript: "fixture-route")
        await service.refresh()
        try await service.apply(model: "new", reasoningEffort: "high", serviceTier: service.preset.serviceTier, contextWindow: service.preset.contextWindow)
        XCTAssertEqual(service.preset.model, "new")
        XCTAssertEqual(desktop.writes, 1)
        desktop.accept = false
        do {
            try await service.apply(model: "ignored", reasoningEffort: "high", serviceTier: service.preset.serviceTier, contextWindow: service.preset.contextWindow)
            XCTFail("读回不一致不能报告成功")
        } catch {}
        XCTAssertEqual(service.preset.model, "new")
    }
}
