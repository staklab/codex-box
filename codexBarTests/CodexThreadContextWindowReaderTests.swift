import Foundation
import XCTest

final class CodexThreadContextWindowReaderTests: XCTestCase {
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
