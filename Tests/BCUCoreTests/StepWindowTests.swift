import CoreGraphics
import XCTest
@testable import BCUCore

/// Whether the session's last step on an app can explain a new window of
/// it. The session's windows are id: app pid; the browser is pid 376.
final class StepWindowTests: XCTestCase {
    private let browser: pid_t = 376

    /// The agent released its browser window 1 s ago while it still holds
    /// two other windows of the browser. The user then opens a window from
    /// another app. The release opened nothing, and its window is gone.
    func testAReleaseOfAnotherWindowDoesntExplainIt() {
        let session: [CGWindowID: pid_t] = [486: browser, 487: browser]
        XCTAssertFalse(WindowManager.stepExplainsNewWindow(sessionWindows: session, pid: browser, stepWindow: 500))
    }

    /// A click in a window the session still has can open a popup.
    func testAStepInAWindowTheSessionStillHasExplainsIt() {
        let session: [CGWindowID: pid_t] = [486: browser, 487: browser]
        XCTAssertTrue(WindowManager.stepExplainsNewWindow(sessionWindows: session, pid: browser, stepWindow: 486))
    }

    /// open_window's step: no window of its own yet.
    func testOpeningAWindowExplainsItWhileTheSessionHasOneInTheApp() {
        XCTAssertTrue(WindowManager.stepExplainsNewWindow(sessionWindows: [486: browser], pid: browser, stepWindow: nil))
        XCTAssertFalse(WindowManager.stepExplainsNewWindow(sessionWindows: [:], pid: browser, stepWindow: nil))
    }
}
