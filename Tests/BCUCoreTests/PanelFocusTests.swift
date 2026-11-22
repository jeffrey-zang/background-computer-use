import XCTest
@testable import BCUCore

/// macOS 15's file panel helper takes the keyboard while an agent's panel
/// is open: during `choose_file` the user's keys are held for exactly that
/// span and replayed after.
final class PanelFocusTests: XCTestCase {
    let helper: pid_t = 429, fixture: pid_t = 1074

    func testOnlyOnMacOS15() {
        XCTAssertTrue(PanelFocus.applies(osMajor: 15))
        XCTAssertFalse(PanelFocus.applies(osMajor: 26))
        XCTAssertFalse(PanelFocus.applies(osMajor: 27))
    }

    func testAKeyGoingToThePanelHelperMidStepIsHeld() {
        XCTAssertTrue(PanelFocus.holds(choosing: true, keyFocus: helper, front: fixture, isHelper: true, userPanelOpen: false))
    }

    func testNothingIsHeldOutsideAStep() {
        XCTAssertFalse(PanelFocus.holds(choosing: false, keyFocus: helper, front: fixture, isHelper: true, userPanelOpen: false))
    }

    func testAKeyGoingToTheAppInFrontGoesOn() {
        XCTAssertFalse(PanelFocus.holds(choosing: true, keyFocus: fixture, front: fixture, isHelper: false, userPanelOpen: false))
        XCTAssertFalse(PanelFocus.holds(choosing: true, keyFocus: 0, front: fixture, isHelper: false, userPanelOpen: false))
        XCTAssertFalse(PanelFocus.holds(choosing: true, keyFocus: 600, front: fixture, isHelper: false, userPanelOpen: false))
    }

    func testTheUsersOwnPanelKeepsTheirKeys() {
        XCTAssertFalse(PanelFocus.holds(choosing: true, keyFocus: helper, front: fixture, isHelper: true, userPanelOpen: true))
    }

    func testAStepCountsUntilJustAfterItEnds() {
        XCTAssertTrue(PanelFocus.choosing(steps: 1, lastEndMs: -1e9, nowMs: 5000))
        XCTAssertTrue(PanelFocus.choosing(steps: 0, lastEndMs: 5000, nowMs: 5000 + PanelFocus.afterStepMs - 1))
        XCTAssertFalse(PanelFocus.choosing(steps: 0, lastEndMs: 5000, nowMs: 5000 + PanelFocus.afterStepMs))
        XCTAssertFalse(PanelFocus.choosing(steps: 0, lastEndMs: -1e9, nowMs: 5000))
    }

    /// Samples every 4 ms from 0 to `to`. The helper has the keyboard except
    /// in `back` spans, and the step runs until `stepEnds`.
    private func run(to: Double, back: [(Double, Double)], stepEnds: Double = .infinity) -> (ms: Double, end: PanelFocus.Hold.End)? {
        var hold = PanelFocus.Hold(helper: helper, sinceMs: 0)
        var t = 0.0
        while t <= to {
            let onHelper = !back.contains { t >= $0.0 && t < $0.1 }
            let choosing = PanelFocus.choosing(steps: t < stepEnds ? 1 : 0, lastEndMs: stepEnds, nowMs: t)
            if let end = hold.sample(helperHasKey: onHelper, choosing: choosing, nowMs: t) { return (t, end) }
            t += 4
        }
        return nil
    }

    /// The step's span as measured on 15.8: the helper lets go for 1.5 and
    /// 7 ms mid-step and takes the keyboard again; the panel closes at 900
    /// ms and the step ends just after. The keys stay held through the step
    /// and go on as soon as the keyboard has been back for `settleMs`.
    func testTheHoldSpansTheStepAndEndsWhenTheKeyboardIsBack() {
        let r = run(to: 1500, back: [(300, 301.5), (600, 607), (900, 99_999)], stepEnds: 905)
        XCTAssertEqual(r?.end, .back)
        XCTAssertGreaterThanOrEqual(r?.ms ?? 0, 900 + PanelFocus.settleMs)
        XCTAssertLessThanOrEqual(r?.ms ?? .infinity, 900 + PanelFocus.settleMs + 8)
    }

    /// A step that fails leaves the panel open, with the helper holding the
    /// keyboard: the keys go on just after it ends.
    func testTheHoldEndsWithTheStep() {
        let r = run(to: 1500, back: [], stepEnds: 700)
        XCTAssertEqual(r?.end, .stepOver)
        XCTAssertGreaterThanOrEqual(r?.ms ?? 0, 700 + PanelFocus.afterStepMs)
        XCTAssertLessThanOrEqual(r?.ms ?? .infinity, 700 + PanelFocus.afterStepMs + 8)
    }

    func testTheHoldEndsAtItsBound() {
        let r = run(to: 10_000, back: [])
        XCTAssertEqual(r?.end, .expired)
        XCTAssertGreaterThanOrEqual(r?.ms ?? 0, PanelFocus.maxHoldMs)
        XCTAssertLessThanOrEqual(r?.ms ?? .infinity, PanelFocus.maxHoldMs + 4)
        XCTAssertLessThanOrEqual(PanelFocus.maxHoldMs, 3000)
    }

    func testABriefLetGoAtTheBoundStillEndsIt() {
        let r = run(to: 10_000, back: [(PanelFocus.maxHoldMs - 2, PanelFocus.maxHoldMs + 5)])
        XCTAssertEqual(r?.end, .expired)
    }

    /// In a batch, choosing starts with the step that opens the picker:
    /// it takes the keyboard as it opens.
    func testABatchChoosesFromTheStepThatOpensThePicker() {
        XCTAssertTrue(Engine.opensPicker(["click", "choose_file"], at: 0))
        XCTAssertTrue(Engine.opensPicker(["click", "wait", "choose_file"], at: 0))
        XCTAssertTrue(Engine.opensPicker(["click", "wait", "choose_file"], at: 1))
        XCTAssertFalse(Engine.opensPicker(["click", "choose_file"], at: 1))
        XCTAssertFalse(Engine.opensPicker(["click", "press_key", "choose_file"], at: 0))
        XCTAssertFalse(Engine.opensPicker(["click"], at: 0))
    }

    /// Replay order: what the user types while the panel has the keyboard,
    /// and after it's back while the held keys are still going on, waits
    /// behind them.
    func testLaterKeysWaitBehindHeldOnes() {
        XCTAssertTrue(FocusGuard.waitsBehind(holding: false, draining: false, queued: false, replaying: false, panelHold: true))
        XCTAssertTrue(FocusGuard.waitsBehind(holding: false, draining: true, queued: false, replaying: false, panelHold: false))
        XCTAssertTrue(FocusGuard.waitsBehind(holding: false, draining: false, queued: true, replaying: false, panelHold: false))
        XCTAssertTrue(FocusGuard.waitsBehind(holding: false, draining: false, queued: false, replaying: true, panelHold: false))
        XCTAssertFalse(FocusGuard.waitsBehind(holding: false, draining: false, queued: false, replaying: false, panelHold: false))
    }
}
