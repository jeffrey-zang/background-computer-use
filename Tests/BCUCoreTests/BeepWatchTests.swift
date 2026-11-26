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

    func testOnlyTheAgentsAppsDuringItsStepsCount() {
        let t0 = Date()
        let step = BeepWatch.Step(start: t0, end: t0.addingTimeInterval(0.35), key: "escape")
        func beep(_ dt: TimeInterval, pid: pid_t = 62902) -> BeepWatch.Beep {
            BeepWatch.Beep(at: t0.addingTimeInterval(dt), pid: pid, app: "TextEdit", action: 4096, seq: 1)
        }
        // During the step, and just after it (the app handles the key late).
        XCTAssertEqual(BeepWatch.agents([beep(0.17), beep(0.9)], pids: [62902], steps: [step]).count, 2)
        // Another app, the user's.
        XCTAssertTrue(BeepWatch.agents([beep(0.17, pid: 1)], pids: [62902], steps: [step]).isEmpty)
        // Long after the step, or before it: the user's own.
        XCTAssertTrue(BeepWatch.agents([beep(3), beep(-1)], pids: [62902], steps: [step]).isEmpty)
        XCTAssertTrue(BeepWatch.agents([beep(0.17)], pids: [62902], steps: []).isEmpty)
    }

    /// A beep logged after its step returned goes to that step's key, not
    /// to the call that finds it.
    func testALateBeepIsPutDownToItsOwnStep() {
        let t0 = Date()
        let escape = BeepWatch.Step(start: t0, end: t0.addingTimeInterval(0.3), key: "escape")
        let save = BeepWatch.Step(start: t0.addingTimeInterval(2), end: t0.addingTimeInterval(2.3), key: "cmd+s")
        let b = BeepWatch.Beep(at: t0.addingTimeInterval(0.2), pid: 7, app: "TextEdit", action: 4096, seq: 1)
        let found = BeepWatch.agents([b], pids: [7], steps: [escape, save])
        XCTAssertEqual(found.first?.step.key, "escape")
        let note = BeepWatch.note(found, current: save.start)!
        XCTAssertTrue(note.hasPrefix("After your previous step: TextEdit beeped"), note)
        XCTAssertTrue(note.contains("escape most likely did nothing"), note)
        XCTAssertFalse(note.contains("cmd+s"), note)
        // Found by its own step: no "previous".
        let own = BeepWatch.note(found, current: escape.start)!
        XCTAssertTrue(own.hasPrefix("TextEdit beeped"), own)
        // Overlapping windows: the latest step it fits.
        let b2 = BeepWatch.Beep(at: t0.addingTimeInterval(2.1), pid: 7, app: "TextEdit", action: 4096, seq: 2)
        XCTAssertEqual(BeepWatch.agents([b2], pids: [7], steps: [BeepWatch.Step(start: t0, end: t0.addingTimeInterval(1.5), key: "escape"), save]).first?.step.key, "cmd+s")
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
