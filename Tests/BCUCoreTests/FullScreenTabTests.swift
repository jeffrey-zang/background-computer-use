import CoreGraphics
import XCTest
@testable import BCUCore

/// The user has an app's window full screen and is in it. With macOS's
/// default tab preference ("Prefer tabs when opening documents: In Full
/// Screen") the app opens any new window as a tab in that window, on the
/// user's screen, and the agent's typing shows there.
final class FullScreenTabTests: XCTestCase {
    func testANewWindowIsATabInTheFullScreenWindowByDefault() {
        XCTAssertTrue(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: nil))
        XCTAssertTrue(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: "fullscreen"))
        XCTAssertTrue(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: "always"))
    }

    /// "Never": the new window is a window of its own.
    func testWithTabsOffItIsntATab() {
        XCTAssertFalse(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: true, tabbingMode: "manual"))
    }

    func testWithNoFullScreenWindowItIsntATab() {
        XCTAssertFalse(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: false, tabbingMode: nil))
        XCTAssertFalse(WindowManager.opensAsTabInFullScreen(keyIsFullScreen: false, tabbingMode: "fullscreen"))
    }

    /// Right after the app relaunched: it restored a full-screen window,
    /// which fills the user's screen, and the document it was opened with
    /// is key, a normal window. A new window is a tab in the full-screen one.
    func testARestoredFullScreenWindowThatIsntKeyTakesTheTab() {
        let windows: [(id: CGWindowID, fullScreen: Bool)] = [(231, false), (170, true)]
        XCTAssertEqual(WindowManager.fullScreenTabHost(key: 231, windows: windows), 170)
        XCTAssertEqual(WindowManager.fullScreenTabHost(key: nil, windows: windows), 170)
    }

    func testTheKeyWindowFirstWhenItIsFullScreen() {
        XCTAssertEqual(WindowManager.fullScreenTabHost(key: 64, windows: [(51, true), (64, true)]), 64)
    }

    func testNoFullScreenWindowNoTab() {
        XCTAssertNil(WindowManager.fullScreenTabHost(key: 231, windows: [(231, false), (52, false)]))
        XCTAssertNil(WindowManager.fullScreenTabHost(key: nil, windows: []))
    }
}
