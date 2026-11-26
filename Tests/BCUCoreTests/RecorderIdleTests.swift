import XCTest
@testable import BCUCore

/// The history recorder and macOS's capture indicator: every capture of
/// the agent display can light the purple dot, so an idle display (no
/// calls, nothing moving) must not be captured at all.
final class RecorderIdleTests: XCTestCase {
    private let long = SessionRecorder.minGapMs * 15

    func testAnIdleDisplayIsNotCaptured() {
        XCTAssertFalse(SessionRecorder.wantsCapture(pending: false, sinceLastCaptureMs: long, windowsChanged: false))
    }

    func testAFrameAfterACallOrAWindowChangeIsTaken() {
        XCTAssertTrue(SessionRecorder.wantsCapture(pending: true, sinceLastCaptureMs: long, windowsChanged: false))
        XCTAssertTrue(SessionRecorder.wantsCapture(pending: false, sinceLastCaptureMs: long, windowsChanged: true))
    }

    func testFramesStillWaitForTheGap() {
        XCTAssertFalse(SessionRecorder.wantsCapture(pending: true, sinceLastCaptureMs: 1000, windowsChanged: true))
    }

    func testAFailureOrANewWindowDoesNotWaitForTheGap() {
        // The agent's screenshots or a live window preview keep the gap shut.
        XCTAssertTrue(SessionRecorder.wantsCapture(pending: true, sinceLastCaptureMs: 200, windowsChanged: false, urgent: true))
        XCTAssertTrue(SessionRecorder.wantsCapture(pending: false, sinceLastCaptureMs: 0, windowsChanged: true, urgent: true,
                                                   sinceOwnCaptureMs: SessionRecorder.urgentGapMs))
        // But not one right after another.
        XCTAssertFalse(SessionRecorder.wantsCapture(pending: false, sinceLastCaptureMs: 200, windowsChanged: true, urgent: true,
                                                    sinceOwnCaptureMs: 300))
    }

    func testANewWindowCountsAsAppearedButAMoveDoesNot() {
        func spot(_ id: CGWindowID, x: CGFloat = 0) -> SessionRecorder.WindowSpot {
            SessionRecorder.WindowSpot(id: id, bounds: CGRect(x: x, y: 0, width: 100, height: 100), title: "", alpha: 1)
        }
        XCTAssertFalse(SessionRecorder.windowAppeared([spot(1)], since: nil))
        XCTAssertFalse(SessionRecorder.windowAppeared([spot(1, x: 50)], since: [spot(1), spot(2)]))
        XCTAssertTrue(SessionRecorder.windowAppeared([spot(1), spot(3)], since: [spot(1)]))
    }

    func testANewWindowMissingFromScreenCaptureKitsListMakesTheCaptureLookAgain() {
        // ScreenCaptureKit's list is cached for 500 ms, so a window that just
        // opened can be missing from it: the capture filters it out.
        XCTAssertEqual(Shot.unlisted([1, 2, 3], in: [1, 3, 9]), [2])
        XCTAssertEqual(Shot.unlisted([1], in: [1]), [])
    }

    func testAWindowTheCaptureLeftOutStillCountsAsNew() {
        func spot(_ id: CGWindowID) -> SessionRecorder.WindowSpot {
            SessionRecorder.WindowSpot(id: id, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), title: "", alpha: 1)
        }
        var tries: [CGWindowID: Int] = [:]
        // Window 2 opened, but the capture's list didn't have it yet.
        var shown = SessionRecorder.spotsShown([spot(1), spot(2)], unlisted: [2], tries: &tries)
        XCTAssertEqual(shown.map(\.id), [1])
        XCTAssertTrue(SessionRecorder.windowAppeared([spot(1), spot(2)], since: shown), "the next tick takes another frame")
        // Once it's listed, the frame has it and it's no longer new.
        shown = SessionRecorder.spotsShown([spot(1), spot(2)], unlisted: [], tries: &tries)
        XCTAssertEqual(shown.map(\.id), [1, 2])
        XCTAssertFalse(SessionRecorder.windowAppeared([spot(1), spot(2)], since: shown))
        XCTAssertTrue(tries.isEmpty)
    }

    func testAWindowScreenCaptureKitNeverListsIsLetGoAfterAFewTries() {
        let s = SessionRecorder.WindowSpot(id: 7, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), title: "", alpha: 1)
        var tries: [CGWindowID: Int] = [:]
        var kept: [CGWindowID] = []
        for _ in 0..<SessionRecorder.maxMissedTries {
            kept = SessionRecorder.spotsShown([s], unlisted: [7], tries: &tries).map(\.id)
        }
        XCTAssertEqual(kept, [7])
        XCTAssertFalse(SessionRecorder.windowAppeared([s], since: [s]))
    }

    func testWindowSpotsSeeMovesAndTitlesButNotTheMenuBarOrTheAppItself() {
        let display = CGRect(x: 3000, y: 0, width: 1440, height: 900)
        func win(_ id: CGWindowID, pid: pid_t = 50, owner: String = "TextEdit", title: String = "Untitled",
                 x: CGFloat = 3100, layer: Int = 0) -> WindowInfo {
            WindowInfo(id: id, pid: pid, owner: owner, title: title, bounds: CGRect(x: x, y: 100, width: 600, height: 400),
                       layer: layer, onScreen: true, alpha: 1)
        }
        let me: pid_t = 99
        let base = [win(1), win(2, owner: "Control Center", layer: 25), win(3, pid: me, owner: "Background Computer Use"),
                    win(4, x: 100)]
        let spots = SessionRecorder.windowSpots(base, on: display, me: me)
        XCTAssertEqual(spots.map(\.id), [1])
        XCTAssertEqual(SessionRecorder.windowSpots([win(1), win(2, owner: "Control Center", title: "12:01", layer: 25)], on: display, me: me), spots)
        XCTAssertNotEqual(SessionRecorder.windowSpots([win(1, x: 3200)], on: display, me: me), spots)
        XCTAssertNotEqual(SessionRecorder.windowSpots([win(1, title: "Loaded")], on: display, me: me), spots)
    }
}
