import XCTest
@testable import BCUCore

/// Issue #96: on a Mac where the agent display came online but wasn't a
/// screen of its own, the agent's windows were on the user's screen and
/// the agent typed into them there. BCU now puts that right (stops the
/// mirroring, gives the main display back, re-places or replaces the
/// display) and refuses, opening nothing, only when none of that works.
final class SeparateDisplayTests: XCTestCase {
    let user = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func place(mirrored: Bool = false, isMain: Bool = false, bounds: CGRect) -> AgentDisplay.Placement {
        AgentDisplay.Placement(mirrored: mirrored, isMain: isMain, bounds: bounds, user: [user])
    }

    /// At the corner of the user's display: separate.
    func testAtTheCornerIsSeparate() {
        XCTAssertNil(AgentDisplay.separationProblem(place(bounds: CGRect(x: 1512, y: 982, width: 1600, height: 1000))))
    }

    /// Touching along an edge shares no area: still separate.
    func testTouchingAnEdgeIsSeparate() {
        XCTAssertNil(AgentDisplay.separationProblem(place(bounds: CGRect(x: 1512, y: 0, width: 1600, height: 1000))))
    }

    /// Mirrored: it has the user's display's place, so its windows are theirs to see.
    func testMirroredIsNotSeparate() {
        let p = AgentDisplay.separationProblem(place(mirrored: true, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000)))
        XCTAssertTrue(p?.contains("mirroring") == true, p ?? "nil")
    }

    func testMainIsNotSeparate() {
        XCTAssertTrue(AgentDisplay.separationProblem(place(isMain: true, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000)))?.contains("main") == true)
    }

    func testOverTheUsersDisplayIsNotSeparate() {
        XCTAssertNotNil(AgentDisplay.separationProblem(place(bounds: CGRect(x: 800, y: 400, width: 1600, height: 1000))))
    }

    func testOfflineIsNotSeparate() {
        XCTAssertNotNil(AgentDisplay.separationProblem(place(bounds: .zero)))
    }

    /// The agent is told nothing happened, and to tell the user.
    func testRefusalSaysNothingWasOpened() {
        let text = AgentDisplay.notSeparateRefusal("macOS is mirroring it with the user's display")
        XCTAssertTrue(text.contains("Nothing was opened"))
        XCTAssertTrue(text.contains("user's own screen"))
        XCTAssertTrue(text.contains("mirroring"))
    }

    /// A display that isn't running has nothing to check.
    func testNotRunningHasNoProblem() {
        XCTAssertNil(AgentDisplay().separationProblem)
    }

    // MARK: Putting it right

    typealias R = AgentDisplay.Remedy

    /// Each problem's own fix comes first.
    func testEachProblemGetsItsOwnFixFirst() {
        XCTAssertEqual(AgentDisplay.remedy(for: .mirrored, tried: [], recreated: false, canRecreate: true), .unmirror)
        XCTAssertEqual(AgentDisplay.remedy(for: .main, tried: [], recreated: false, canRecreate: true), .makeUserMain)
        XCTAssertEqual(AgentDisplay.remedy(for: .overlaps(user), tried: [], recreated: false, canRecreate: true), .replace)
        XCTAssertEqual(AgentDisplay.remedy(for: .offline, tried: [], recreated: false, canRecreate: true), .recreate)
    }

    /// The fix didn't take (macOS mirrors it again): a new display, whose
    /// serial macOS has nothing remembered for.
    func testThenANewDisplay() {
        XCTAssertEqual(AgentDisplay.remedy(for: .mirrored, tried: [.unmirror], recreated: false, canRecreate: true), .recreate)
    }

    /// A problem that changed into another gets that one's fix before a new display.
    func testAnotherProblemGetsItsFixToo() {
        XCTAssertEqual(AgentDisplay.remedy(for: .main, tried: [.unmirror], recreated: false, canRecreate: true), .makeUserMain)
    }

    /// The new display gets its own fix once more, then BCU refuses.
    func testTheNewDisplayGetsOneFixThenRefusal() {
        XCTAssertEqual(AgentDisplay.remedy(for: .mirrored, tried: [], recreated: true, canRecreate: true), .unmirror)
        XCTAssertNil(AgentDisplay.remedy(for: .mirrored, tried: [.unmirror], recreated: true, canRecreate: true))
        XCTAssertNil(AgentDisplay.remedy(for: .offline, tried: [], recreated: true, canRecreate: true))
    }

    /// A display with the agent's windows on it isn't replaced: they'd land
    /// on the user's screen when it goes.
    func testNoNewDisplayUnderTheAgentsWindows() {
        XCTAssertNil(AgentDisplay.remedy(for: .mirrored, tried: [.unmirror], recreated: false, canRecreate: false))
        XCTAssertEqual(AgentDisplay.remedy(for: .main, tried: [], recreated: false, canRecreate: false), .makeUserMain)
    }

    /// The user display that was main gets that back; else the built-in
    /// one; else the lowest ID.
    func testWhichUserDisplayBecomesMain() {
        XCTAssertEqual(AgentDisplay.userMain(users: [1, 5, 9], last: 5, builtin: [1]), 5)
        XCTAssertEqual(AgentDisplay.userMain(users: [3, 9], last: 5, builtin: [9]), 9)
        XCTAssertEqual(AgentDisplay.userMain(users: [9, 3], last: 0, builtin: []), 3)
        XCTAssertNil(AgentDisplay.userMain(users: [], last: 5, builtin: []))
    }

    /// The new main display goes to 0,0 and the others keep their places around it.
    func testUserDisplaysKeepTheirPlacesAroundTheNewMain() {
        // The agent display took 0,0 and pushed the user's displays right.
        let o = AgentDisplay.userMainOrigins(users: [1: CGRect(x: 1600, y: 0, width: 1512, height: 982),
                                                     2: CGRect(x: 3112, y: -200, width: 1920, height: 1080)], main: 1)
        XCTAssertEqual(o[1], CGPoint(x: 0, y: 0))
        XCTAssertEqual(o[2], CGPoint(x: 1512, y: -200))
        XCTAssertTrue(AgentDisplay.userMainOrigins(users: [2: .zero], main: 1).isEmpty)
    }

    /// Mid-session, at most 5 tries in any 10 s: a fight with macOS ends.
    func testMidSessionTriesAreLimited() {
        XCTAssertTrue(AgentDisplay.recoveryDue([], now: 0))
        XCTAssertTrue(AgentDisplay.recoveryDue([1, 2, 3, 4], now: 5))
        XCTAssertFalse(AgentDisplay.recoveryDue([1, 2, 3, 4, 5], now: 6))
        XCTAssertTrue(AgentDisplay.recoveryDue([1, 2, 3, 4, 5], now: 10_002))
    }

    /// The refusal says what was tried.
    func testRefusalSaysWhatWasTried() {
        let text = AgentDisplay.notSeparateRefusal("macOS is mirroring it with the user's display", tried: [.unmirror, .recreate, .unmirror])
        XCTAssertTrue(text.contains("stopping the mirroring, then replacing it with a new display, then stopping the mirroring didn't change that"), text)
        XCTAssertFalse(AgentDisplay.notSeparateRefusal("x").contains("didn't change"))
    }

    func testSeparationTexts() {
        XCTAssertEqual(AgentDisplay.separation(place(mirrored: true, bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000))), .mirrored)
        XCTAssertEqual(AgentDisplay.separation(place(bounds: CGRect(x: 800, y: 400, width: 1600, height: 1000))), .overlaps(user))
        XCTAssertEqual(AgentDisplay.Separation.main.text, "macOS made it the main display")
    }
}
