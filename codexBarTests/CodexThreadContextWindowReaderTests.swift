import Foundation
import XCTest

final class CodexThreadContextWindowReaderTests: XCTestCase {
    func testBranchIgnoresInheritedWindowUntilNewTurnReports() {
        let inherited = Data("""
        {"timestamp":"2026-09-08T00:00:00.000Z","type":"turn_context","payload":{"model":"model"}}
        {"timestamp":"2026-09-08T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        """.utf8)
        let cutoff = Date(timeIntervalSince1970: 1788825602)
        XCTAssertNil(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: inherited, model: "model", after: cutoff))
        let fresh = inherited + Data("""

        {"timestamp":"2026-09-08T00:00:03.000Z","type":"turn_context","payload":{"model":"model"}}
        {"timestamp":"2026-09-08T00:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":117283}}}
        """.utf8)
        XCTAssertEqual(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: fresh, model: "model", after: cutoff), 117283)
    }

    func testDoesNotReuseWindowFromAnotherModelOrEarlierTurn() {
        let data = Data("""
        {"type":"turn_context","payload":{"model":"old"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        {"type":"turn_context","payload":{"model":"new"}}
        """.utf8)
        XCTAssertNil(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: data, model: "new"))
        XCTAssertNil(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: data, model: "old"))
        let completed = data + Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"model_context_window\":828400}}}".utf8)
        XCTAssertEqual(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: completed, model: "new"), 828400)
        XCTAssertNil(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: completed, model: "old"))
    }

    func testReturnsLatestEffectiveWindowFromTokenCountEvents() {
        let data = Data("""
        {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":245100}}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":828400}}}
        """.utf8)

        XCTAssertEqual(
            CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: data),
            828_400
        )
    }

    func testIgnoresMalformedTrailingLineAndUnrelatedContextField() {
        let data = Data("""
        {"type":"session_meta","payload":{"model_context_window":999999}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":258400}}}
        {"type":"event_msg","payload":{"type":"token_count","info":
        """.utf8)

        XCTAssertEqual(
            CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: data),
            258_400
        )
    }

    func testReturnsNilWhenNoEffectiveWindowExists() {
        let data = Data("""
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8)

        XCTAssertNil(CodexThreadContextWindowReader.latestEffectiveContextWindow(inRolloutTail: data))
    }
}
