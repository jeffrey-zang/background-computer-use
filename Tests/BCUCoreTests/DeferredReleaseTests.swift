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
}
