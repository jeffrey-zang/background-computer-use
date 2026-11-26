import XCTest
@testable import BCUCore

/// #101: a tab another app opens in an agent's browser window goes to the user.
final class StrayTabTests: XCTestCase {
    private let now = 100_000.0

    func testANewSelectedTabWithNoStepJustNowIsAnotherApps() {
        XCTAssertTrue(WindowManager.strayTab(newSelected: true, lastActionMs: now - 5000, nowMs: now, userDriving: false))
        XCTAssertTrue(WindowManager.strayTab(newSelected: true, lastActionMs: nil, nowMs: now, userDriving: false))
    }

    func testAStepsOwnNewTabStaysTheAgents() {
        // A link that opens a tab, cmd+T: during the step or just after.
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: now, nowMs: now, userDriving: false))
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: now - 1000, nowMs: now, userDriving: false))
    }

    func testNoNewSelectedTabIsNothing() {
        // A tab opened in the background, or one closed.
        XCTAssertFalse(WindowManager.strayTab(newSelected: false, lastActionMs: nil, nowMs: now, userDriving: false))
    }

    func testNotWhileTheUserDrivesTheAgentDisplay() {
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: nil, nowMs: now, userDriving: true))
    }
}
