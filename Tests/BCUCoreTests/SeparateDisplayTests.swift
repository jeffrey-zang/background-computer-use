import XCTest
@testable import BCUCore

/// Issue #96: on a Mac where the agent display came online but wasn't a
/// screen of its own, the agent's windows were on the user's screen and
/// the agent typed into them there. BCU now says so and opens nothing.
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
}
