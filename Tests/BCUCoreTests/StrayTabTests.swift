import XCTest
@testable import BCUCore

/// #101: a tab another app opens in an agent's browser window goes to the user.
final class StrayTabTests: XCTestCase {
    private let seen = 100_000.0

    func testANewSelectedTabWithNoStepSinceItWasLastSeenIsAnotherApps() {
        XCTAssertTrue(WindowManager.strayTab(newSelected: true, lastActionMs: seen - 5000, sinceMs: seen, userDriving: false))
        XCTAssertTrue(WindowManager.strayTab(newSelected: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
    }

    func testAStepsOwnNewTabStaysTheAgents() {
        // A link that opens a tab, cmd+T: during the step, or just before
        // the tabs were last seen and showing up after.
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: seen + 200, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: seen - 1000, sinceMs: seen, userDriving: false))
    }

    /// The check ran late (the shared queue was busy with another browser's
    /// handout): a step since the tabs were last seen still explains the
    /// tab, however long ago it ended by the time the check runs.
    func testAStepSinceTheLastLookExplainsTheTabHoweverLateTheCheck() {
        let stepEnded = seen + 300
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: stepEnded, sinceMs: seen, userDriving: false))
    }

    func testNoNewSelectedTabIsNothing() {
        // A tab opened in the background, or one closed.
        XCTAssertFalse(WindowManager.strayTab(newSelected: false, lastActionMs: nil, sinceMs: seen, userDriving: false))
    }

    func testNotWhileTheUserDrivesTheAgentDisplay() {
        XCTAssertFalse(WindowManager.strayTab(newSelected: true, lastActionMs: nil, sinceMs: seen, userDriving: true))
    }

    /// Looked at again under the input lock: a step that waited for it may
    /// have gone back to the agent's own tab, and Move Tab to New Window
    /// takes whichever is selected.
    func testTheTabIsHandedOutOnlyIfStillSelectedWithNoStepSince() {
        XCTAssertTrue(WindowManager.strayStillSelected(selected: true, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(selected: false, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(selected: nil, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(selected: true, inWindow: false, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(selected: true, inWindow: true, lastActionMs: seen + 50, sinceMs: seen, userDriving: false))
    }

    /// The handout itself is upkeep, not a step: when it has to wait (focus
    /// couldn't be taken), the next look still sees the tab as another app's.
    func testTheHandoutIsntCountedAsAnAgentStep() {
        let guardian = FocusGuard()
        let pid: pid_t = 999_901
        guardian.beginAction(pid: pid, cause: "upkeep", upkeep: true)
        XCTAssertNil(guardian.lastActionMs(pid))
        guardian.endAction(pid: pid, upkeep: true)
        XCTAssertNil(guardian.lastActionMs(pid))

        guardian.beginAction(pid: pid, cause: "a step")
        XCTAssertNotNil(guardian.lastActionMs(pid))
        guardian.endAction(pid: pid)
        XCTAssertNotNil(guardian.lastActionMs(pid))
    }
}
