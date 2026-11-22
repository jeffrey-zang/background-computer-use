import XCTest
@testable import BCUCore

/// Pure rules only: nothing here reads or touches the Mac it runs on.
final class SetupAudioTests: XCTestCase {
    /// TCC's preflight: 0 allowed, 1 denied, 2 not asked, -1 no preflight.
    func testPreflightAnswers() {
        XCTAssertEqual(AudioAccess(preflight: 0), .allowed)
        XCTAssertEqual(AudioAccess(preflight: 1), .denied)
        XCTAssertEqual(AudioAccess(preflight: 2), .notAsked)
        XCTAssertEqual(AudioAccess(preflight: -1), .unavailable)
    }

    /// Setup asks until it's allowed, and has nothing to ask without a preflight.
    func testSetupShowsTheStepUntilAllowed() {
        XCTAssertTrue(AudioAccess.notAsked.setupShows)
        XCTAssertTrue(AudioAccess.denied.setupShows)
        XCTAssertFalse(AudioAccess.allowed.setupShows)
        XCTAssertFalse(AudioAccess.unavailable.setupShows)
    }
}
