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
        XCTAssertTrue(WindowManager.strayStillSelected(agentsWindow: true, selected: true, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(agentsWindow: true, selected: false, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(agentsWindow: true, selected: nil, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(agentsWindow: true, selected: true, inWindow: false, lastActionMs: nil, sinceMs: seen, userDriving: false))
        XCTAssertFalse(WindowManager.strayStillSelected(agentsWindow: true, selected: true, inWindow: true, lastActionMs: seen + 50, sinceMs: seen, userDriving: false))
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

    /// Handed off to the user while the check waited for the lock: the
    /// user may be in that window now, and its tab is theirs to keep.
    func testAWindowHandedToTheUserMeanwhileIsLeftAlone() {
        XCTAssertFalse(WindowManager.strayStillSelected(agentsWindow: false, selected: true, inWindow: true, lastActionMs: nil, sinceMs: seen, userDriving: false))
    }

    /// The moved tab's window came after the handout stopped waiting: the
    /// next new standard window of the browser is it, not one an agent's
    /// step opened, so it's the user's and never closed with the agent's.
    func testALateWindowFromMoveTabIsTheUsers() {
        let pending = (before: Set<CGWindowID>([1, 2]), untilMs: seen + 10_000, title: "TAB OPENED BY CODEX")
        let title = "TAB OPENED BY CODEX - Google Chrome"
        func late(_ id: CGWindowID, standard: Bool = true, registered: Bool = false, opening: Bool = false, title t: String? = title,
                  pending p: (before: Set<CGWindowID>, untilMs: Double, title: String)? = pending, at now: Double = seen) -> Bool {
            WindowManager.isLateHandout(id: id, standard: standard, registered: registered, opening: opening, windowTitle: t, pending: p, nowMs: now)
        }
        XCTAssertTrue(late(3))
        // One that was there before, a popup, too late, or none pending.
        XCTAssertFalse(late(2))
        XCTAssertFalse(late(3, standard: false))
        XCTAssertFalse(late(3, at: seen + 10_001))
        XCTAssertFalse(late(3, pending: nil))
        // A session's window, or one opening now: its catcher's.
        XCTAssertFalse(late(3, registered: true))
        XCTAssertFalse(late(3, opening: true))
        // A window the agent's own keys or clicks opened (cmd+N, a popup):
        // it doesn't show the moved tab.
        XCTAssertFalse(late(3, title: "New Tab - Google Chrome"))
        XCTAssertFalse(late(3, title: nil))
        XCTAssertFalse(late(3, pending: (before: [1, 2], untilMs: seen + 10_000, title: "")))
    }

    /// After a handout the baseline is the tabs from before it, less the
    /// moved one: a tab another link opened while it ran is still new.
    func testATabThatCameDuringAHandoutIsStillNew() {
        let known = WindowManager.knownAfterHandout(before: [1, 2, 3], after: [1, 2, 4], moved: 3) { $0 == $1 }
        XCTAssertEqual(known, [1, 2])
    }

    /// One pending handout claims one window: a second new window in the
    /// same sweep (an agent's popup), or another session's sweep, gets none.
    func testALateHandoutIsTakenOnce() {
        let pid: pid_t = 999_902
        WindowManager.setLateHandoutForTesting(pid: pid, before: [1], untilMs: seen)
        XCTAssertTrue(WindowManager.takeLateHandout(pid: pid, untilMs: seen))
        XCTAssertFalse(WindowManager.takeLateHandout(pid: pid, untilMs: seen))
    }

    /// A tab strip read that came back incomplete isn't the window's tabs:
    /// saved as the baseline, the missing tab would look new next time.
    func testAnIncompleteTabStripReadIsNoRead() {
        XCTAssertEqual(WindowManager.tabStrip([("AXRadioButton", "AXTabButton"), ("AXButton", nil), ("AXRadioButton", "AXTabButton")]), [0, 2])
        XCTAssertNil(WindowManager.tabStrip([("AXRadioButton", "AXTabButton"), ("AXRadioButton", nil)]))
        XCTAssertNil(WindowManager.tabStrip([("AXRadioButton", "AXTabButton"), (nil, nil)]))
        XCTAssertEqual(WindowManager.tabStrip([("AXButton", nil)]), [])
    }

    /// A menu press that failed outright moved nothing: no late window is
    /// waited for (it would claim the agent's next popup as the user's).
    func testOnlyAPressThatMayHaveRunWaitsForAWindow() {
        XCTAssertTrue(WindowManager.menuPressMayHaveRun(.success))
        XCTAssertTrue(WindowManager.menuPressMayHaveRun(.cannotComplete))
        XCTAssertFalse(WindowManager.menuPressMayHaveRun(.invalidUIElement))
        XCTAssertFalse(WindowManager.menuPressMayHaveRun(.actionUnsupported))
    }

    /// An open in a browser with a moved tab's window still on its way
    /// waits for it: its catcher would take that window as the agent's.
    func testAnOpenSeesAPendingHandout() {
        let pid: pid_t = 999_903
        XCTAssertNil(WindowManager.lateHandoutUntil(pid))
        WindowManager.setLateHandoutForTesting(pid: pid, before: [], untilMs: seen)
        XCTAssertEqual(WindowManager.lateHandoutUntil(pid), seen)
        XCTAssertTrue(WindowManager.takeLateHandout(pid: pid, untilMs: seen))
        XCTAssertNil(WindowManager.lateHandoutUntil(pid))
    }
}
