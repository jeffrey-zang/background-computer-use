import XCTest
import BCUShared
@testable import BCUCore

/// Issue #87, problems 1 and 2: an agent's browser coming forward over the
/// user's app during steps that need no key focus, and being left in front
/// on input of the user's that was in another app.
final class SelfActivationTests: XCTestCase {
    let user: pid_t = 101, agent: pid_t = 202, other: pid_t = 303
    var list: Set<UInt64> = []
    func psn(_ pid: pid_t) -> UInt64 { 0x1_0000_0000 + UInt64(pid) }

    override func setUp() {
        super.setUp()
        list = []
        let apps = [user, agent, other].map { FrontGate.App(asn: "\($0)" as CFString, pid: $0, bundleID: "test.app.\($0)") }
        var system = FrontGate.System()
        system.runningApps = { apps }
        system.appListSeed = { 1 }
        system.currentList = { nil }
        system.setList = { _ in -10663 }
        system.frontPid = { [unowned self] in user }
        system.windowServerListAvailable = { true }
        system.processSerialNumber = { [unowned self] in psn($0) }
        system.updateWindowServerList = { [unowned self] p, add in
            if add { list.insert(p) } else { list.remove(p) }
            return 0
        }
        FrontGate.system = system
    }

    override func tearDown() {
        FrontGate.system = FrontGate.System()
        super.tearDown()
    }

    func gate(_ targets: FrontGate.Targets) -> FrontGate {
        let g = FrontGate()
        g.targets = { targets }
        g.tapWorking = { true }
        for _ in 0..<3 { _ = g.passForTests() }
        return g
    }

    // MARK: Problem 1: the gate keeps the agent's app back on the user's input in their own app

    /// The user clicks in their own app's window while an agent scrolls in
    /// the browser: the browser stays off the list, so its asking for the
    /// front is refused, during the click and after the pass that follows.
    func testAClickInTheUsersOwnWindowKeepsTheSteppingAppBack() {
        let g = gate(FrontGate.Targets(pids: [agent], stepping: [agent]))
        g.pointer(down: true, ms: 1000, on: user)
        XCTAssertFalse(list.contains(psn(agent)))
        g.pointer(down: false, ms: 1000)
        _ = g.passForTests()
        XCTAssertFalse(list.contains(psn(agent)))
        XCTAssertTrue(g.blocks(agent))
        g.stop()
    }

    /// The same just after a step, while it can still bring the app forward
    /// (a page loading after a press on a link, a batch's single click).
    func testAClickInTheUsersOwnWindowKeepsTheSettlingAppBack() {
        let g = gate(FrontGate.Targets(pids: [agent], settling: [agent]))
        g.pointer(down: true, ms: 1000, on: user)
        g.pointer(down: false, ms: 1000)
        _ = g.passForTests()
        XCTAssertFalse(list.contains(psn(agent)))
        g.stop()
    }

    /// A click on the agent's app's own window is the user going there: it goes through.
    func testAClickOnTheAgentsAppLetsItThrough() {
        let g = gate(FrontGate.Targets(pids: [agent], stepping: [agent]))
        g.pointer(down: true, ms: 1000, on: agent)
        XCTAssertTrue(list.contains(psn(agent)))
        _ = g.passForTests()
        XCTAssertTrue(list.contains(psn(agent)))
        g.stop()
    }

    /// A click whose app can't be told (the Dock, the menu bar, a
    /// notification) lets everyone through, as before.
    func testAClickOnSomethingElseLetsEveryoneThrough() {
        let g = gate(FrontGate.Targets(pids: [agent], stepping: [agent]))
        g.pointer(down: true, ms: 1000, on: nil)
        XCTAssertTrue(list.contains(psn(agent)))
        g.stop()
    }

    /// A click in the user's window with no agent acting (only a window
    /// open in the app) lets the app through: a link they click may open there.
    func testAClickLetsAnAppWithNoStepThrough() {
        let g = gate(FrontGate.Targets(pids: [agent]))
        g.pointer(down: true, ms: 1000, on: user)
        XCTAssertTrue(list.contains(psn(agent)))
        g.stop()
    }

    /// Return in the user's chat app just after an agent's press on a link
    /// keeps the browser back while the page loads (it was only kept back
    /// while the step itself ran, a few milliseconds).
    func testAKeyKeepsTheSettlingAppBack() {
        let g = gate(FrontGate.Targets(pids: [agent], settling: [agent]))
        g.liftForKey(ms: 1500)
        XCTAssertFalse(list.contains(psn(agent)))
        _ = g.passForTests()
        XCTAssertFalse(list.contains(psn(agent)))
        g.stop()
    }

    /// A later click on the agent's app within the same lift still gets
    /// through, whatever was clicked before.
    func testASecondClickOnTheAgentsAppGetsThrough() {
        let g = gate(FrontGate.Targets(pids: [agent], stepping: [agent]))
        g.pointer(down: true, ms: 1000, on: user)
        g.pointer(down: false, ms: 1000)
        XCTAssertFalse(list.contains(psn(agent)))
        g.pointer(down: true, ms: 1000, on: agent)
        XCTAssertTrue(list.contains(psn(agent)))
        g.stop()
    }

    /// The user clicks in their app every moment, the first time before
    /// the agent's step began (that click let everyone through): the next
    /// click, during the step, keeps the agent's app back again.
    func testAClickInTheUsersWindowAfterAnOpenOneKeepsTheAppBack() {
        let g = gate(FrontGate.Targets(pids: [agent], stepping: [agent]))
        g.pointer(down: true, ms: 1000, on: nil)
        g.pointer(down: false, ms: 1000)
        XCTAssertTrue(list.contains(psn(agent)))
        g.pointer(down: true, ms: 1000, on: user)
        g.pointer(down: false, ms: 1000)
        _ = g.passForTests()
        XCTAssertFalse(list.contains(psn(agent)))
        g.stop()
    }

    func testNarrowed() {
        let want = FrontGate.Targets(pids: [agent, other], stepping: [agent], settling: [other])
        XCTAssertEqual(FrontGate.narrowed(want, want: want, open: true, keyOpen: false, clickOpen: false, clicked: []).pids, [])
        XCTAssertEqual(FrontGate.narrowed(want, want: want, open: false, keyOpen: false, clickOpen: true, clicked: [user]).pids, [agent, other])
        XCTAssertEqual(FrontGate.narrowed(want, want: want, open: false, keyOpen: false, clickOpen: true, clicked: [other]).pids, [agent])
        XCTAssertEqual(FrontGate.narrowed(want, want: want, open: false, keyOpen: true, clickOpen: false, clicked: []).pids, [agent, other])
        let idle = FrontGate.Targets(pids: [agent, other])
        XCTAssertEqual(FrontGate.narrowed(idle, want: idle, open: false, keyOpen: true, clickOpen: false, clicked: []).pids, [])
        XCTAssertEqual(FrontGate.narrowed(idle, want: idle, open: false, keyOpen: false, clickOpen: false, clicked: []).pids, [agent, other])
    }

    /// What a click is surely in, for the gate.
    func testGateOwner() {
        // An ordinary window under the Dock's pass-through window over the screen.
        XCTAssertEqual(ClickTarget.gateOwner([(pid: 9, dock: true, layer: 20, coversDisplay: true), (pid: user, dock: false, layer: 0, coversDisplay: false)]), user)
        // A Dock icon.
        XCTAssertNil(ClickTarget.gateOwner([(pid: 9, dock: true, layer: 20, coversDisplay: false), (pid: user, dock: false, layer: 0, coversDisplay: false)]))
        // The menu bar, a notification: above ordinary windows.
        XCTAssertNil(ClickTarget.gateOwner([(pid: 7, dock: false, layer: 25, coversDisplay: false), (pid: user, dock: false, layer: 0, coversDisplay: false)]))
        XCTAssertNil(ClickTarget.gateOwner([]))
        // Notification Center's window over the whole screen, which clicks pass through.
        XCTAssertEqual(ClickTarget.gateOwner([(pid: 8, dock: false, layer: 25, coversDisplay: true), (pid: user, dock: false, layer: 0, coversDisplay: false)]), user)
        // A full-screen app's own window is ordinary.
        XCTAssertEqual(ClickTarget.gateOwner([(pid: agent, dock: false, layer: 0, coversDisplay: true)]), agent)
        XCTAssertEqual(ClickTarget.gateOwner([(pid: agent, dock: false, layer: 0, coversDisplay: false)]), agent)
    }

    // MARK: Problem 2: left in front on the user's input that was in another app

    private let now = 10_000.0
    private var running: Attribution.Step { Attribution.Step(running: 1, settleUntilMs: .infinity, strict: false) }

    private func facts(mouseDown: Double = -1e9, switchKey: Double = -1e9, clickOnApp: Bool = true, switcherOpen: Bool = false) -> Attribution.Facts {
        Attribution.Facts(nowMs: now, step: running, restoredAwayMs: nil, lastMouseDownMs: mouseDown, lastSwitchKeyMs: switchKey,
                          lastOpenKeyMs: -1e9, arrivedElsewhereMs: -1e9, clickOnApp: clickOnApp, switcherOpen: switcherOpen)
    }

    /// The browser came forward while the user held command after cmd+Tab:
    /// the switch hadn't happened, so it's the agent's.
    func testCmdTabWithTheSwitcherStillUpExplainsNothing() {
        XCTAssertTrue(Attribution.agentCaused(facts(switchKey: now - 150, switcherOpen: true)))
        XCTAssertEqual(Attribution.credit(facts(switchKey: now - 150, switcherOpen: true)), .none)
    }

    /// Once command is let go, the cmd+Tab is theirs, as before.
    func testCmdTabOnceLetGoIsTheirs() {
        XCTAssertFalse(Attribution.agentCaused(facts(switchKey: now - 150)))
        XCTAssertEqual(Attribution.credit(facts(switchKey: now - 150)), .switchKey)
        XCTAssertEqual(Attribution.credit(facts(mouseDown: now - 100)), .click)
    }

    private func left(_ credit: Attribution.Credit, front: Bool = true, movedOn: Bool = false, acting: Bool = true,
                      target: ClickTarget = .app(202), wasIn: pid_t? = nil, switcher: Bool = false) -> Attribution.Left {
        Attribution.Left(credit: credit, front: front, movedOn: movedOn, acting: acting, clickTarget: target, clickWasIn: wasIn, switcherOpen: switcher)
    }

    /// Accessibility says, after the decision, that the click was in the
    /// user's own app: put their app back.
    func testAClickThatTurnsOutToBeInAnotherAppIsReverted() {
        XCTAssertTrue(Attribution.revert(left(.click, target: .app(user)), pid: agent))
    }

    /// The browser raised its window over the very spot before
    /// accessibility was asked: the look from before the click says the
    /// user's window was on top there.
    func testAClickOnTheUsersWindowThatTheAppCoveredIsReverted() {
        XCTAssertTrue(Attribution.revert(left(.click, target: .app(agent), wasIn: user), pid: agent))
    }

    /// Their click really was on the agent's app: leave it.
    func testAClickOnTheAgentsAppStays() {
        XCTAssertFalse(Attribution.revert(left(.click, target: .app(agent), wasIn: agent), pid: agent))
        XCTAssertFalse(Attribution.revert(left(.click, target: .dock(agent)), pid: agent))
        XCTAssertFalse(Attribution.revert(left(.click, target: .app(agent), wasIn: nil), pid: agent))
    }

    /// A click accessibility says was on the app's Dock icon stays, whatever
    /// the look from before (the Dock may have been hidden then) had there.
    func testAConfirmedDockClickOnTheAppStays() {
        XCTAssertFalse(Attribution.revert(left(.click, target: .dock(agent), wasIn: user), pid: agent))
    }

    /// For an app kept back on a click: a title that changed by itself is
    /// nothing; a new window is; a changed title is after a link.
    func testAKeptAppIsBroughtForwardOnlyForWhatTheClickCouldHaveOpened() {
        let before: [CGWindowID: String] = [10: "Inbox (3)"]
        XCTAssertNil(LateLook.keptOpened(element: .unknown, before: before, now: [10: "Inbox (4)"]))
        XCTAssertNil(LateLook.keptOpened(element: nil, before: before, now: [10: "Inbox (4)"]))
        XCTAssertEqual(LateLook.keptOpened(element: .unknown, before: before, now: [10: "Inbox (3)", 11: "New"]), 11)
        XCTAssertEqual(LateLook.keptOpened(element: .link, before: before, now: [10: "Example"]), 10)
        XCTAssertNil(LateLook.keptOpened(element: .link, before: nil, now: [10: "Example"]))
        // Not before the guard has had time to catch a window an agent's step opened.
        XCTAssertNil(LateLook.keptOpened(element: .unknown, before: before, now: [10: "Inbox (3)", 11: "Popup"], newWindowsCount: false))
    }

    func testACmdTabStaysUnlessTheSwitcherWasUp() {
        XCTAssertFalse(Attribution.revert(left(.switchKey), pid: agent))
        XCTAssertTrue(Attribution.revert(left(.switchKey, switcher: true), pid: agent))
    }

    /// Not once the user did something since, the app left the front, or
    /// no agent is acting on it any more.
    func testNothingIsRevertedOnceItsNotTheAgentsMoment() {
        let wrong = left(.click, target: .app(user))
        var l = wrong; l.movedOn = true
        XCTAssertFalse(Attribution.revert(l, pid: agent))
        l = wrong; l.front = false
        XCTAssertFalse(Attribution.revert(l, pid: agent))
        l = wrong; l.acting = false
        XCTAssertFalse(Attribution.revert(l, pid: agent))
        XCTAssertFalse(Attribution.revert(left(.none), pid: agent))
    }
}

/// A restore that's under way when the app comes forward again doesn't
/// drop it: the browser stayed in front for 3.6 s.
final class RestoreAgainTests: XCTestCase {
    func testAFirstRestoreAlwaysLooksAgain() {
        XCTAssertTrue(FocusGuard.restoresAgain(again: false, missed: false))
    }
    func testALaterRestoreLooksAgainOnlyIfTheAppCameForwardMeanwhile() {
        XCTAssertFalse(FocusGuard.restoresAgain(again: true, missed: false))
        XCTAssertTrue(FocusGuard.restoresAgain(again: true, missed: true))
    }
}
