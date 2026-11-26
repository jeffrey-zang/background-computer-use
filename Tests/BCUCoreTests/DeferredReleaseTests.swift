import XCTest
import BCUShared
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

    /// A second release_window while the app still hangs, with another
    /// keep_open: the pending release is the latest one, and the finish
    /// reads it then rather than what the sweep saw.
    func testTheLatestKeepOpenWins() {
        let m = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: "deferred-k-\(UUID().uuidString)")
        let id: CGWindowID = 4_000_000_003
        m.register(AgentWindow(id: id, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        defer { m.unregister(id) }
        m.deferRelease(id, keepOpen: false)
        m.deferRelease(id, keepOpen: true)
        XCTAssertEqual(m.pendingRelease(id), true)
    }

    /// status answers off the engine's queue; it carries the note too.
    func testStatusCarriesTheNote() {
        let base = ToolResult(text: "status")
        XCTAssertEqual(Engine.withNote(base, nil).text, "status")
        XCTAssertEqual(Engine.withNote(base, "\n[released window] Window 7 didn't close").text, "status\n[released window] Window 7 didn't close")
    }

    /// The agent goes away (or BCU quits) while the app still hangs: the
    /// cleanup's release keeps the keep_open the agent asked for, rather than
    /// replacing it with keep_open: false.
    func testCleanupKeepsTheAgentsKeepOpen() {
        let m = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: "deferred-c-\(UUID().uuidString)")
        let kept: CGWindowID = 4_000_000_004, plain: CGWindowID = 4_000_000_005
        m.register(AgentWindow(id: kept, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        m.register(AgentWindow(id: plain, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        defer { m.unregister(kept); m.unregister(plain) }
        m.deferRelease(kept, keepOpen: true)
        XCTAssertTrue(m.keepOpenOnCleanup(kept))
        XCTAssertFalse(m.keepOpenOnCleanup(plain))
    }

    /// BCU quits or crashes while a keep_open release is still waiting:
    /// the record says so, and the next launch's recovery leaves the window.
    func testAKeepOpenThatWaitsSurvivesARestart() throws {
        let key = "deferred-p-\(UUID().uuidString)"
        let m = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: key)
        let id: CGWindowID = 4_000_000_006
        m.register(AgentWindow(id: id, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        defer { m.unregister(id) }
        m.deferRelease(id, keepOpen: true)
        let url = BCUPaths.supportDirectory.appendingPathComponent("windows-\(key).json")
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let e = try XCTUnwrap(entries.first { $0["id"] as? Int == Int(id) })
        XCTAssertEqual(e["keepOpen"] as? Bool, true)
        XCTAssertFalse(WindowManager.recoveryCloses(entry: e))
        XCTAssertTrue(WindowManager.recoveryCloses(entry: ["kind": "opened"]))
        XCTAssertFalse(WindowManager.recoveryCloses(entry: ["kind": "opened", "handedToUser": true]))
    }

    /// A takeover runs in turn with the old session (its engine's queue):
    /// a deferred finish it has started completes before the windows move.
    func testTakeOverWaitsForTheOldSessionsTurn() {
        let a = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: "deferred-t-\(UUID().uuidString)")
        let b = WindowManager(display: AgentDisplay(), focusGuard: FocusGuard(), sessionKey: "deferred-u-\(UUID().uuidString)")
        let q = DispatchQueue(label: "old-session")
        a.inTurn = { q.sync(execute: $0) }
        let id: CGWindowID = 4_000_000_007
        a.register(AgentWindow(id: id, pid: 1, appName: "Dia", bundleID: nil, kind: .opened))
        defer { b.unregister(id) }
        var order: [String] = []
        let started = expectation(description: "finish started")
        q.async { started.fulfill(); Thread.sleep(forTimeInterval: 0.2); order.append("finish") }
        wait(for: [started], timeout: 5)
        XCTAssertEqual(b.takeOver(from: a), 1)
        order.append("takeover")
        XCTAssertEqual(order, ["finish", "takeover"])
        XCTAssertNotNil(b.window(id))
    }
}
