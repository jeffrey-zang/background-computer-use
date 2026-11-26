import XCTest
@testable import BCUCore

/// Pure rules only: nothing here starts `log` or listens for sounds.
final class BeepWatchTests: XCTestCase {
    /// The line `systemsoundserverd` logs for TextEdit's NSBeep (macOS 26.1).
    let line = #"{"timestamp":"2026-11-26 02:55:21.804543-0800","eventMessage":"   -> Incoming Request : actionID 4096, inClientPID 62902(TextEdit), inBehavior 1, customVibeDataProvided 0, loop 0","processID":73505}"#

    func testParsesTheRequestLine() {
        let b = BeepWatch.parse(line: Data(line.utf8), seq: 7)
        XCTAssertEqual(b?.pid, 62902)
        XCTAssertEqual(b?.app, "TextEdit")
        XCTAssertEqual(b?.action, BeepWatch.alertAction)
        XCTAssertEqual(b?.seq, 7)
        XCTAssertEqual(b?.at.timeIntervalSince1970 ?? 0, 1795690521.804, accuracy: 0.01)
    }

    func testAppNamesWithSpacesAndOtherLines() {
        let m = BeepWatch.parse(message: "Incoming Request : actionID 1, inClientPID 9541(Safari Web Content), inBehavior 1")
        XCTAssertEqual(m?.app, "Safari Web Content")
        XCTAssertEqual(m?.pid, 9541)
        XCTAssertEqual(m?.action, 1)
        XCTAssertNil(BeepWatch.parse(message: "Outgoing Reply : 4096"))
        XCTAssertNil(BeepWatch.parse(line: Data("not json".utf8), seq: 1))
        XCTAssertNil(BeepWatch.parse(line: Data(#"{"eventMessage":"Start of stream"}"#.utf8), seq: 1))
    }

    func step(_ t0: Date, _ from: TimeInterval, _ to: TimeInterval, key: String? = "escape", pids: Set<pid_t> = [62902], owner: String = "a", call: Date? = nil) -> BeepWatch.Step {
        BeepWatch.Step(start: t0.addingTimeInterval(from), end: t0.addingTimeInterval(to), key: key, pids: pids, owner: owner, call: call ?? t0.addingTimeInterval(from))
    }
    func beep(_ t0: Date, _ dt: TimeInterval, pid: pid_t = 62902, seq: Int = 1) -> BeepWatch.Beep {
        BeepWatch.Beep(at: t0.addingTimeInterval(dt), pid: pid, app: "TextEdit", action: 4096, seq: seq)
    }

    func testOnlyTheAgentsAppsDuringItsStepsCount() {
        let t0 = Date()
        let s = [step(t0, 0, 0.35)]
        // During the step, and just after it (the app handles the key late).
        XCTAssertEqual(BeepWatch.agents([beep(t0, 0.17), beep(t0, 0.9)], steps: s, owner: "a").count, 2)
        // Another app, the user's.
        XCTAssertTrue(BeepWatch.agents([beep(t0, 0.17, pid: 1)], steps: s, owner: "a").isEmpty)
        // Long after the step, or before it: the user's own.
        XCTAssertTrue(BeepWatch.agents([beep(t0, 3), beep(t0, -1)], steps: s, owner: "a").isEmpty)
        XCTAssertTrue(BeepWatch.agents([beep(t0, 0.17)], steps: [], owner: "a").isEmpty)
    }

    /// A beep logged after its call returned goes to that call's key, not
    /// to the call that finds it.
    func testALateBeepIsPutDownToItsOwnStep() {
        let t0 = Date()
        let escape = step(t0, 0, 0.3), save = step(t0, 2, 2.3, key: "cmd+s")
        let found = BeepWatch.agents([beep(t0, 0.2)], steps: [escape, save], owner: "a")
        XCTAssertEqual(found.first?.step.key, "escape")
        let note = BeepWatch.note(found, current: save.call)!
        XCTAssertTrue(note.hasPrefix("After your previous step: TextEdit beeped"), note)
        XCTAssertTrue(note.contains("escape most likely did nothing"), note)
        XCTAssertFalse(note.contains("cmd+s"), note)
        // Found by its own call: no "previous".
        XCTAssertTrue(BeepWatch.note(found, current: escape.call)!.hasPrefix("TextEdit beeped"))
        // Overlapping windows: the latest input it fits.
        XCTAssertEqual(BeepWatch.agents([beep(t0, 2.1)], steps: [step(t0, 0, 1.5), save], owner: "a").first?.step.key, "cmd+s")
    }

    /// Two sessions in one app: a beep goes to the one whose input it
    /// followed, not also to one that was waiting its turn meanwhile.
    func testTwoSessionsInOneAppReportItOnce() {
        let t0 = Date()
        // b's call began at 0 but waited for a's step; it sent at 2.
        let a = step(t0, 1.0, 1.2, owner: "a")
        let b = step(t0, 2.0, 2.2, key: "return", owner: "b", call: t0)
        let found = beep(t0, 1.15)
        XCTAssertEqual(BeepWatch.agents([found], steps: [a, b], owner: "a").count, 1)
        XCTAssertTrue(BeepWatch.agents([found], steps: [a, b], owner: "b").isEmpty)
        // b's own beep, during its sending, is b's even within a's tail.
        let late = beep(t0, 2.1)
        XCTAssertEqual(BeepWatch.agents([late], steps: [a, b], owner: "b").first?.step.key, "return")
        XCTAssertTrue(BeepWatch.agents([late], steps: [a, b], owner: "a").isEmpty)
    }

    /// Input still being sent is listed already: a beep during it isn't put
    /// down to the step before it, another session's, whose tail it's in.
    func testInputBeingSentIsListedBeforeItEnds() {
        let w = BeepWatch()
        let t0 = Date()
        w.record(step(t0, -0.5, -0.3, owner: "a"))
        let id = w.begin(BeepWatch.Step(start: t0, end: .distantFuture, key: "return", pids: [62902], owner: "b", call: t0))
        let b = beep(t0, 0.1)
        XCTAssertTrue(BeepWatch.agents([b], steps: w.recentSteps, owner: "a").isEmpty)
        XCTAssertEqual(BeepWatch.agents([b], steps: w.recentSteps, owner: "b").count, 1)
        w.finish(id)
        XCTAssertLessThan(w.recentSteps.last!.end, Date.distantFuture)
        XCTAssertEqual(BeepWatch.agents([b], steps: w.recentSteps, owner: "b").count, 1)
    }

    /// A beep reported to one session isn't taken over by input another
    /// session starts after it.
    func testALaterInputCantTakeAReportedBeep() {
        let w = BeepWatch()
        let t0 = Date()
        w.record(step(t0, 0, 0.2, owner: "a"))
        let b = beep(t0, 0.29)
        XCTAssertEqual(w.attribute([b], owner: "a").count, 1)
        w.record(step(t0, 0.29, 0.5, key: "return", owner: "b"))
        XCTAssertTrue(w.attribute([b], owner: "b").isEmpty)
        XCTAssertEqual(w.attribute([b], owner: "a").count, 1)
        // And input that began after the request can't win it at all.
        XCTAssertEqual(BeepWatch.agents([beep(t0, 0.31)], steps: [step(t0, 0, 0.2, owner: "a"), step(t0, 0.32, 0.5, owner: "b")], owner: nil).first?.step.owner, "a")
    }

    /// A beep is put down to its input as it arrives: the input can be
    /// pruned (a long batch) before the call looks, and the beep is kept.
    func testABeepKeepsItsInputPastPruning() {
        let w = BeepWatch()
        let t0 = Date()
        w.record(step(t0, -0.1, 0.2, owner: "a"))
        let start = w.lastSeq
        w.inject((t0.addingTimeInterval(0.1), 62902, "TextEdit", 4096))
        w.forgetSteps()
        let found = w.attribute(w.beeps(after: start), owner: "a")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.step.key, "escape")
    }

    /// A beep that arrives while the session's next call is under way, and
    /// fits only the tail of its last call's input, isn't settled on
    /// arrival: the call under way may list its own input still.
    func testABeepDuringTheNextCallWaitsForItsInput() {
        let w = BeepWatch()
        let t0 = Date()
        w.record(step(t0, 0, 0.2, key: "escape", owner: "a", call: t0))
        let next = t0.addingTimeInterval(0.5)
        w.beginCall("a", at: next)
        let start = w.lastSeq
        w.inject((t0.addingTimeInterval(0.7), 62902, "TextEdit", 4096))
        // The call lists its input (an open_window's shortcut) late, then looks.
        w.record(step(t0, 0.6, 0.8, key: nil, owner: "a", call: next))
        w.endCall("a")
        let found = w.attribute(w.beeps(after: start), owner: "a")
        XCTAssertEqual(found.first?.step.call, next)
    }

    /// A beep put down to a call still under way is kept however many
    /// other requests come in meanwhile, until that call has looked.
    func testAPendingBeepOutlivesPruning() {
        let w = BeepWatch()
        let t0 = Date()
        w.beginCall("a", at: t0.addingTimeInterval(-1))
        w.record(BeepWatch.Step(start: t0.addingTimeInterval(-0.1), end: t0.addingTimeInterval(0.2), key: "escape", pids: [62902], owner: "a", call: t0.addingTimeInterval(-1)))
        let start = w.lastSeq
        w.inject((t0, 62902, "TextEdit", 4096))
        for _ in 0..<300 { w.inject((Date(), 1, "Finder", 16)) }   // unrelated requests: pruned to 256
        XCTAssertEqual(w.attribute(w.beeps(after: start), owner: "a").count, 1)
        w.endCall("a")
        w.inject((Date(), 1, "Finder", 16))
        XCTAssertFalse(w.beeps(after: start).contains { $0.app == "TextEdit" })
    }

    /// Completed input is pruned on the begin/finish path too.
    func testFinishPrunes() {
        let w = BeepWatch()
        for _ in 0..<300 {
            let id = w.begin(BeepWatch.Step(start: Date(), end: .distantFuture, key: nil, pids: [1], owner: "a", call: Date()))
            w.finish(id)
        }
        XCTAssertLessThanOrEqual(w.recentSteps.count, 200)
    }

    /// A call that only waits isn't input to the app.
    func testWaitingIsNotInput() {
        XCTAssertFalse(Engine.acts("batch", ["actions": [["tool": "wait", "ms": 500]]]))
        XCTAssertTrue(Engine.acts("batch", ["actions": [["tool": "wait", "ms": 500], ["tool": "click", "element": 3]]]))
        XCTAssertTrue(Engine.acts("click", [:]))
        XCTAssertFalse(Engine.acts("capture_audio", [:]))
        XCTAssertFalse(Engine.acts("take_back", [:]))
    }

    /// Keys sent to an open or save panel's service: its beeps count.
    func testAPanelServiceBeepCounts() {
        let t0 = Date()
        let s = [step(t0, 0, 0.3, pids: [62902, 777])]
        XCTAssertEqual(BeepWatch.agents([beep(t0, 0.2, pid: 777)], steps: s, owner: "a").count, 1)
    }

    func testNoteNamesTheAppAndTheKey() {
        let b = BeepWatch.Beep(at: Date(), pid: 1, app: "TextEdit", action: 4096, seq: 1)
        let one = BeepWatch.note([b], key: "escape")!
        XCTAssertTrue(one.hasPrefix("TextEdit beeped (its alert sound, which plays on the user's speakers)."), one)
        XCTAssertTrue(one.contains("escape most likely did nothing there"), one)
        let two = BeepWatch.note([b, b], key: nil)!
        XCTAssertTrue(two.contains("TextEdit beeped 2 times"), two)
        XCTAssertTrue(two.contains("the input most likely did nothing"), two)
        let other = BeepWatch.note([BeepWatch.Beep(at: Date(), pid: 1, app: "Finder", action: 16, seq: 1)], key: nil)!
        XCTAssertEqual(other, "Finder played a system sound on the user's speakers.")
        XCTAssertNil(BeepWatch.note([], key: "escape"))
    }

    func testInjectedBeepsAreReportedOnce() {
        let w = BeepWatch()
        let start = w.lastSeq
        w.inject((Date(), 5, "TextEdit", 4096))
        let fresh = w.beeps(after: start)
        XCTAssertEqual(fresh.count, 1)
        XCTAssertTrue(w.beeps(after: fresh.last!.seq).isEmpty)
    }
}
