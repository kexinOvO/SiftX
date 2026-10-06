import XCTest
@testable import SafariExtensionState

final class ToolbarBadgeTests: XCTestCase {
    func testDisablingClearsBadgeAndRejectsInFlightCountsUntilReenabled() {
        let state = ToolbarBadgeState<String>()
        let first = state.beginValidation(for: "window")
        XCTAssertTrue(state.update(for: "window", requestID: first.requestID, count: 2))
        let inFlight = state.beginValidation(for: "window")
        let disabled = state.beginValidation(for: "window", showsBadge: false)
        XCTAssertEqual(disabled.text, "")
        XCTAssertFalse(state.update(for: "window", requestID: inFlight.requestID, count: 3))
        XCTAssertFalse(state.update(for: "window", requestID: disabled.requestID, count: 3))
        XCTAssertEqual(state.beginValidation(for: "window", showsBadge: false).text, "")

        let enabled = state.beginValidation(for: "window")
        XCTAssertEqual(enabled.text, "")
        XCTAssertTrue(state.update(for: "window", requestID: enabled.requestID, count: 3))
        XCTAssertEqual(state.beginValidation(for: "window").text, "3")
    }

    func testHidingBadgeDoesNotAffectOtherWindows() {
        let state = ToolbarBadgeState<String>()
        for window in ["A", "B"] {
            let scan = state.beginValidation(for: window)
            XCTAssertTrue(state.update(for: window, requestID: scan.requestID, count: 2))
        }
        XCTAssertEqual(state.beginValidation(for: "A", showsBadge: false).text, "")
        XCTAssertEqual(state.beginValidation(for: "B").text, "2")
    }

    func testRepeatedScansKeepBadgeVisibleAndSkipIdenticalUpdates() {
        let state = ToolbarBadgeState<String>()
        let first = state.beginValidation(for: "window")
        XCTAssertEqual(first.text, "")
        XCTAssertTrue(state.update(for: "window", requestID: first.requestID, count: 1))
        for _ in 0..<100 {
            let scan = state.beginValidation(for: "window")
            XCTAssertEqual(scan.text, "1")
            XCTAssertFalse(state.update(for: "window", requestID: scan.requestID, count: 1))
        }
    }

    func testLateQueryCannotClearBadgeFromNewerPage() {
        let state = ToolbarBadgeState<String>()
        let old = state.beginValidation(for: "window")
        let current = state.beginValidation(for: "window")
        XCTAssertTrue(state.update(for: "window", requestID: current.requestID, count: 2))
        XCTAssertFalse(state.update(for: "window", requestID: old.requestID, count: 0))
        XCTAssertEqual(state.beginValidation(for: "window").text, "2")
    }

    func testWindowsStayIndependentAndEmptyPageClearsBadge() {
        let state = ToolbarBadgeState<String>()
        let a = state.beginValidation(for: "A")
        XCTAssertTrue(state.update(for: "A", requestID: a.requestID, count: 100))
        XCTAssertEqual(state.beginValidation(for: "A").text, "99")
        XCTAssertEqual(state.beginValidation(for: "B").text, "")
        let empty = state.beginValidation(for: "A")
        XCTAssertTrue(state.update(for: "A", requestID: empty.requestID, count: 0))
        XCTAssertEqual(state.beginValidation(for: "A").text, "")
    }
}
