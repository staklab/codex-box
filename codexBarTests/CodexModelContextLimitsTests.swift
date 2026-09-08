import XCTest

final class CodexModelContextLimitsTests: XCTestCase {
    func testCurrentCatalogLimitsAllPresets() {
        let limits = CodexModelContextLimits(maximum: 872000, effectivePercent: 95)
        XCTAssertEqual(CodexBarGlobalSettings.presetContextWindows.map { limits.estimatedWindow(configured: $0) },
                       [245100, 486400, 828400, 828400])
        XCTAssertEqual(limits.estimatedWindow(configured: 123456), 117283)
    }

    func testModelSpecificLimitsAndUnknownMetadata() {
        let data = Data(#"{"models":[{"slug":"a","max_context_window":1000000,"effective_context_window_percent":90},{"slug":"b","max_context_window":2000000,"effective_context_window_percent":100},{"slug":"missing"},{"slug":"invalid","max_context_window":10,"effective_context_window_percent":110}]}"#.utf8)
        XCTAssertEqual(CodexModelContextLimits.decode(data: data, model: "a")?.estimatedWindow(configured: 1050000), 900000)
        XCTAssertEqual(CodexModelContextLimits.decode(data: data, model: "b")?.estimatedWindow(configured: 1050000), 1050000)
        for model in ["unknown", "missing", "invalid"] {
            XCTAssertNil(CodexModelContextLimits.decode(data: data, model: model))
        }
        XCTAssertNil(CodexModelContextLimits.decode(data: Data(), model: "a"))
    }
}
