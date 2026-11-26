import XCTest
@testable import BCUCore

/// release_window on a window whose app wasn't answering accessibility (a
/// hung Dia window) threw "try again in a moment" and did nothing else. The
/// agent gave up on the window and opened another, and every window it gave
/// up on stayed open (issue #99). Now the release is finished by the sweep
/// once the app answers.
final class DeferredReleaseTests: XCTestCase {
    func testAWindowStillListedButUnreachableIsWaitedFor() {
        XCTAssertEqual(WindowManager.deferredReleaseStep(listed: true, reachable: false, userInControl: false), .wait)
    }

    func testItIsReleasedOnceTheAppAnswers() {
        XCTAssertEqual(WindowManager.deferredReleaseStep(listed: true, reachable: true, userInControl: false), .finish)
    }

    func testAWindowThatWentAwayIsForgotten() {
        XCTAssertEqual(WindowManager.deferredReleaseStep(listed: false, reachable: false, userInControl: false), .forget)
        XCTAssertEqual(WindowManager.deferredReleaseStep(listed: false, reachable: false, userInControl: true), .forget)
    }

    /// release_window is refused while the user drives the display; the
    /// sweep doesn't close a window under them either.
    func testNotWhileTheUserIsInControl() {
        XCTAssertEqual(WindowManager.deferredReleaseStep(listed: true, reachable: true, userInControl: true), .wait)
    }

    func testTheAgentIsToldItNeedNotReleaseAgain() {
        let text = WindowManager.deferredReleaseText(app: "Dia", id: 42, borrowed: false, keepOpen: false)
        XCTAssertTrue(text.contains("window 42 is still open"))
        XCTAssertTrue(text.contains("closes it as soon as Dia answers"))
        XCTAssertTrue(text.contains("don't need to release it again"))
        XCTAssertTrue(WindowManager.deferredReleaseText(app: "Dia", id: 42, borrowed: true, keepOpen: false).contains("puts it back"))
        XCTAssertTrue(WindowManager.deferredReleaseText(app: "Dia", id: 42, borrowed: false, keepOpen: true).contains("leaves it open"))
    }

    /// The app answers with a dialog (unsaved changes): that's the agent's to
    /// answer, so it's told, and the sweep stops closing the window again.
    func testADialogOnceTheAppAnswersGoesBackToTheAgent() {
        XCTAssertEqual(WindowManager.deferredOutcome(stillRegistered: true, stillPending: false), .needsAgent)
        XCTAssertEqual(WindowManager.deferredOutcome(stillRegistered: true, stillPending: true), .again)
        XCTAssertEqual(WindowManager.deferredOutcome(stillRegistered: false, stillPending: false), .done)
        let text = WindowManager.deferredNeedsAgentText(app: "TextEdit", id: 7, said: "window 7 didn't close: TextEdit is asking \"Save?\"")
        XCTAssertTrue(text.contains("Window 7, which you released while TextEdit wasn't answering, didn't close"))
        XCTAssertTrue(text.contains("is asking \"Save?\""))
    }

    /// Checked again in turn with the tool calls: a window handed to the
    /// user meanwhile is left alone, and so is one no longer pending.
    func testAHandedOffWindowIsNotClosedByTheSweep() {
        let w = AgentWindow(id: 1, pid: 1, appName: "Dia", bundleID: nil, kind: .opened)
        XCTAssertTrue(WindowManager.mayFinishDeferred(w, pending: true, userInControl: false))
        XCTAssertFalse(WindowManager.mayFinishDeferred(w, pending: false, userInControl: false))
        XCTAssertFalse(WindowManager.mayFinishDeferred(w, pending: true, userInControl: true))
        XCTAssertFalse(WindowManager.mayFinishDeferred(nil, pending: true, userInControl: false))
        w.handedOff = true
        XCTAssertFalse(WindowManager.mayFinishDeferred(w, pending: true, userInControl: false))
    }

    /// A session taking over another's windows takes their pending
    /// releases too, keep_open and all.
    func testTakeOverKeepsAPendingRelease() {
        let a = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: "deferred-a-\(UUID().uuidString)")
        let b = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: "deferred-b-\(UUID().uuidString)")
        let id: CGWindowID = 4_000_000_001, other: CGWindowID = 4_000_000_002
        a.register(AgentWindow(id: id, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        a.register(AgentWindow(id: other, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        a.deferRelease(id, keepOpen: true)
        defer { b.unregister(id); b.unregister(other) }
        XCTAssertEqual(b.takeOver(from: a), 2)
        XCTAssertEqual(b.pendingRelease(id), true)
        XCTAssertNil(b.pendingRelease(other))
        XCTAssertNil(a.pendingRelease(id))
        XCTAssertNil(a.window(id))
    }
}
