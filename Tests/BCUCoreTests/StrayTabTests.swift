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
        func late(_ id: CGWindowID, standard: Bool = true, registered: Bool = false, opening: Bool = false, title t: String? = title, stepSince: Bool = true,
                  pending p: (before: Set<CGWindowID>, untilMs: Double, title: String)? = pending, at now: Double = seen) -> Bool {
            WindowManager.isLateHandout(id: id, standard: standard, registered: registered, opening: opening, windowTitle: t, stepSince: stepSince, pending: p, nowMs: now)
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
        // With no agent step since the move, nothing else could have made
        // it: the user's even if its page loaded or redirected meanwhile.
        XCTAssertTrue(late(3, title: "Redirected page - Google Chrome", stepSince: false))
        XCTAssertTrue(late(3, title: nil, stepSince: false))
        XCTAssertFalse(late(3, standard: false, stepSince: false))
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

    /// After a tab was moved out of the agent's window, its last read (and
    /// the element numbers from it) is out of date until it reads again.
    func testElementNumbersFromBeforeAHandoutAreStale() {
        XCTAssertTrue(Engine.staleAfterTabMovedOut(movedMs: seen + 10, readMs: seen))
        XCTAssertTrue(Engine.staleAfterTabMovedOut(movedMs: seen, readMs: nil))
        XCTAssertFalse(Engine.staleAfterTabMovedOut(movedMs: seen, readMs: seen + 10))
        XCTAssertFalse(Engine.staleAfterTabMovedOut(movedMs: nil, readMs: seen))
    }

    /// The moved tab's window is the one showing it, not a popup an
    /// earlier step opened that comes up while the tab moves.
    func testTheMovedTabsWindowShowsTheTab() {
        XCTAssertTrue(WindowManager.windowShowsTab(windowTitle: "TAB OPENED BY CODEX - Google Chrome", tabTitle: "TAB OPENED BY CODEX"))
        XCTAssertFalse(WindowManager.windowShowsTab(windowTitle: "Sign in - Google Accounts - Google Chrome", tabTitle: "TAB OPENED BY CODEX"))
        XCTAssertFalse(WindowManager.windowShowsTab(windowTitle: nil, tabTitle: "TAB OPENED BY CODEX"))
        XCTAssertTrue(WindowManager.windowShowsTab(windowTitle: "Anything", tabTitle: ""))
    }

    /// The tab's own context menu moves it whatever window has key: its
    /// item when the browser has no other window, else the submenu's.
    func testTheTabsMenuItemThatMovesItToANewWindow() {
        let alone = ["New Tab to the Right", "Add Tab to New Group", "Move Tab to New Window", "", "Reload", "Close"]
        XCTAssertEqual(WindowManager.tabMenuMove(alone, enabled: alone.map { !$0.isEmpty }), .item(2))
        let others = ["New Tab to the Right", "Add Tab to New Group", "Move Tab to Another Window", "", "Reload"]
        XCTAssertEqual(WindowManager.tabMenuMove(others, enabled: others.map { !$0.isEmpty }), .submenu(2))
        XCTAssertEqual(WindowManager.tabMenuNewWindow(["New Window", "", "USER'S PAGE - Google Chrome"]), 0)
        XCTAssertNil(WindowManager.tabMenuNewWindow(["USER'S PAGE - Google Chrome"]))
        // Case differs between Chromium builds' menus.
        XCTAssertEqual(WindowManager.tabMenuMove(["Move tab to new window"], enabled: [true]), .item(0))
        // Disabled, or not there (another language): none, and the menu bar is tried.
        XCTAssertNil(WindowManager.tabMenuMove(["Move Tab to New Window"], enabled: [false]))
        XCTAssertNil(WindowManager.tabMenuMove(["Reload", "Close"], enabled: [true, true]))
    }

    /// A delayed window.open: Chromium puts the page's new tab right after
    /// its opener, a link from another app at the end of the strip.
    func testANewTabBeforeAKnownTabWasOpenedByAPage() {
        // [agent's page, its other tab] + a tab inserted between them.
        XCTAssertTrue(WindowManager.openedByPage(known: [true, false, true], at: 1))
        // At the end: could be another app's link.
        XCTAssertFalse(WindowManager.openedByPage(known: [true, false], at: 1))
        XCTAssertFalse(WindowManager.openedByPage(known: [true, true, false], at: 2))
        // Two new at the end: still nothing known after it.
        XCTAssertFalse(WindowManager.openedByPage(known: [true, false, false], at: 1))
        XCTAssertFalse(WindowManager.openedByPage(known: [true], at: 3))
    }

    /// The context-menu route has no key scope: key goes back to the
    /// window the user was typing in before their held keys are replayed.
    func testKeyAfterTheTabsMenuMovedIt() {
        XCTAssertEqual(WindowManager.keyAfterTabMenuMove(userIn: true, userKey: 7, made: 9), 7)
        XCTAssertNil(WindowManager.keyAfterTabMenuMove(userIn: true, userKey: nil, made: 9))
        XCTAssertEqual(WindowManager.keyAfterTabMenuMove(userIn: false, userKey: nil, made: 9), 9)
    }

    /// A hard AXShowMenu error showed no menu: nothing open then is this tab's.
    func testOnlyAShowMenuThatMayHaveRunIsUsed() {
        XCTAssertTrue(WindowManager.showMenuMayHaveRun(.success))
        XCTAssertTrue(WindowManager.showMenuMayHaveRun(.cannotComplete))
        XCTAssertFalse(WindowManager.showMenuMayHaveRun(.actionUnsupported))
        XCTAssertFalse(WindowManager.showMenuMayHaveRun(.invalidUIElement))
    }

    /// Two links between looks, [agent, A, B] with B selected: B is moved,
    /// and A, never judged, stays new for the next look.
    func testATabThatCameWithTheMovedOneStaysNew() {
        let known = WindowManager.knownAfterHandout(before: [1], after: [1, 2], moved: 3) { $0 == $1 }
        XCTAssertEqual(known, [1])
    }

    /// A step ran since the handout, so the late window is told by its
    /// title; an unreadable title waits for a later look.
    func testALateWindowWithAnUnreadableTitleWaitsWhenTheTitleDecides() {
        XCTAssertTrue(WindowManager.lateHandoutNeedsTitle(stepSince: true, title: nil))
        XCTAssertFalse(WindowManager.lateHandoutNeedsTitle(stepSince: true, title: "X - Google Chrome"))
        XCTAssertFalse(WindowManager.lateHandoutNeedsTitle(stepSince: false, title: nil))
    }

    /// The automatic handout waits for a held key or button, a menu, typing
    /// and a password field, like a step that takes key does.
    func testTheHandoutWaitsForTheUsersInput() {
        XCTAssertNil(WindowManager.handoutBlocker(focusSensitive: nil, secureInput: false, typing: false))
        XCTAssertEqual(WindowManager.handoutBlocker(focusSensitive: nil, secureInput: true, typing: false), QuietWait.secureReason)
        XCTAssertEqual(WindowManager.handoutBlocker(focusSensitive: "the user to let go of the mouse button", secureInput: false, typing: false),
                       "the user to let go of the mouse button")
        XCTAssertEqual(WindowManager.handoutBlocker(focusSensitive: nil, secureInput: false, typing: true), QuietWait.typingReason)
    }

    /// Taking the reservation and keeping the window happen together: a
    /// second claim finds the reservation gone and the window kept.
    func testALateHandoutIsClaimedAndKeptInOneStep() {
        let pid: pid_t = 99_101
        let until = nowMs() + 5000
        WindowManager.setLateHandoutForTesting(pid: pid, before: [], untilMs: until)
        XCTAssertTrue(WindowManager.claimLateHandout(pid: pid, untilMs: until, id: 990_101))
        XCTAssertTrue(WindowManager.isKept(990_101))
        XCTAssertFalse(WindowManager.claimLateHandout(pid: pid, untilMs: until, id: 990_102))
        XCTAssertFalse(WindowManager.isKept(990_102))
    }

    /// A move whose window came late: claiming it marks the agent's window
    /// as changed then, so a read taken while it was pending isn't fresh.
    func testALateMoveMarksTheSourceWindowWhenItLands() {
        let pid: pid_t = 99_102
        let until = nowMs() + 5000
        WindowManager.setLateHandoutForTesting(pid: pid, before: [], untilMs: until, source: 990_200)
        let readWhilePending = nowMs()
        XCTAssertTrue(WindowManager.claimLateHandout(pid: pid, untilMs: until, id: 990_201))
        XCTAssertTrue(Engine.staleAfterTabMovedOut(movedMs: WindowManager.tabMovedOutMs(990_200), readMs: readWhilePending))
    }

    /// A mute button named before a handout isn't pressed once it's in
    /// another window (the user's).
    func testAMuteButtonInAnotherWindowIsNotPressed() {
        XCTAssertTrue(AudioClaims.movedAway(now: 12, from: 11))
        XCTAssertFalse(AudioClaims.movedAway(now: 11, from: 11))
        XCTAssertFalse(AudioClaims.movedAway(now: nil, from: 11))
    }
}
