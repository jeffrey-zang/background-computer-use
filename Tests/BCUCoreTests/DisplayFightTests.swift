import XCTest
import CoreGraphics
@testable import BCUCore

/// Agent displays next to another app's virtual display (#110): they're
/// placed by the user's displays only, stay wherever macOS leaves them as
/// long as that's out of the way, and move a bounded number of times.
final class DisplayFightTests: XCTestCase {
    let user = CGRect(x: 0, y: 0, width: 1680, height: 1050)
    let size = CGSize(width: 1600, height: 1000)
    func at(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: size) }

    // MARK: acceptable

    func testMeetingTheUserAtACornerIsFine() {
        XCTAssertTrue(AgentDisplay.acceptable(at(1680, 1050), user: [user], others: [user]))
    }

    /// Along an edge of the user's display the cursor walks straight onto
    /// it (a new virtual display comes online at -1600,0, say).
    func testAlongTheUsersEdgeIsNot() {
        XCTAssertFalse(AgentDisplay.acceptable(at(-1600, 0), user: [user], others: [user]))
        XCTAssertFalse(AgentDisplay.acceptable(at(1680, 0), user: [user], others: [user]))
        XCTAssertFalse(AgentDisplay.acceptable(at(0, 1050), user: [user], others: [user]))
    }

    func testCoveringAnotherDisplayIsNot() {
        let other = at(1680, 1050)
        XCTAssertFalse(AgentDisplay.acceptable(at(1680, 1050), user: [user], others: [user, other]))
        XCTAssertFalse(AgentDisplay.acceptable(at(2000, 1500), user: [user], others: [user, other]))
    }

    /// Next to another app's display, or another agent display, along an
    /// edge: fine. Neither is the user's.
    func testAlongAnotherAppsDisplayIsFine() {
        let theirs = at(1680, 1050)
        XCTAssertTrue(AgentDisplay.acceptable(at(3280, 1050), user: [user], others: [user, theirs]))
        XCTAssertTrue(AgentDisplay.acceptable(at(1680, 2050), user: [user], others: [user, theirs]))
    }

    func testSharesEdge() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertTrue(AgentDisplay.sharesEdge(a, CGRect(x: 10, y: 5, width: 10, height: 10)))
        XCTAssertTrue(AgentDisplay.sharesEdge(a, CGRect(x: -5, y: 10, width: 10, height: 10)))
        XCTAssertFalse(AgentDisplay.sharesEdge(a, CGRect(x: 10, y: 10, width: 10, height: 10)))
        XCTAssertFalse(AgentDisplay.sharesEdge(a, CGRect(x: 20, y: 0, width: 10, height: 10)))
    }

    // MARK: spot

    func testTheStaircaseCornerWhenItsFree() {
        XCTAssertEqual(AgentDisplay.spot(size: size, preferred: CGPoint(x: 1680, y: 1050), user: [user], others: [user]),
                       CGPoint(x: 1680, y: 1050))
    }

    /// Another app's display already at the corner stays there: this one
    /// goes past it instead of pushing it aside.
    func testAnotherAppsDisplayAtTheCornerIsSteppedOver() {
        let theirs = at(1680, 1050)
        let p = AgentDisplay.spot(size: size, preferred: CGPoint(x: 1680, y: 1050), user: [user], others: [user, theirs])
        XCTAssertEqual(p, CGPoint(x: 3280, y: 2050))
        XCTAssertTrue(AgentDisplay.acceptable(CGRect(origin: p, size: size), user: [user], others: [user, theirs]))
    }

    /// One that's not quite at the corner (overlapping it) too.
    func testAnOverlappingDisplayIsSteppedOver() {
        let theirs = at(2000, 1050)
        let p = AgentDisplay.spot(size: size, preferred: CGPoint(x: 1680, y: 1050), user: [user], others: [user, theirs])
        XCTAssertTrue(AgentDisplay.acceptable(CGRect(origin: p, size: size), user: [user], others: [user, theirs]))
    }

    // MARK: anchor displays

    func testOtherAppsVirtualDisplaysAreNotTheUsers() {
        XCTAssertEqual(AgentDisplay.anchorDisplays([1, 136], isVirtual: { $0 == 136 }), [1])
    }

    /// Every display virtual (DisplayLink screens only, say): all of them.
    func testOnlyVirtualDisplaysAreAllTheUsers() {
        XCTAssertEqual(AgentDisplay.anchorDisplays([5, 6], isVirtual: { _ in true }), [5, 6])
    }

    // MARK: needsPlacing

    func testStaysPutWhenOnlyOthersMoved() {
        let theirs = at(1680, 1050)
        XCTAssertFalse(AgentDisplay.needsPlacing(at(3280, 2050), wanted: CGPoint(x: 1680, y: 1050), userChanged: false,
                                                 user: [user], others: [user, theirs]))
    }

    func testGoesBackWhenTheUsersDisplaysChanged() {
        XCTAssertTrue(AgentDisplay.needsPlacing(at(3280, 2050), wanted: CGPoint(x: 1680, y: 1050), userChanged: true,
                                                user: [user], others: [user]))
    }

    func testMovesWhenMacOSLeftItAlongTheUsersEdge() {
        XCTAssertTrue(AgentDisplay.needsPlacing(at(1680, 0), wanted: CGPoint(x: 1680, y: 1050), userChanged: false,
                                                user: [user], others: [user]))
    }

    /// macOS put it elsewhere the last time it was asked for this spot:
    /// not asked again, unless the user's displays changed since (a corner
    /// contact can have become a shared edge).
    func testARefusalIsRetriedOnlyWhenTheUsersDisplaysChanged() {
        XCTAssertFalse(AgentDisplay.tryPlacing(needed: true, refusedBefore: true, userChanged: false))
        XCTAssertTrue(AgentDisplay.tryPlacing(needed: true, refusedBefore: true, userChanged: true))
        XCTAssertTrue(AgentDisplay.tryPlacing(needed: true, refusedBefore: false, userChanged: false))
        XCTAssertFalse(AgentDisplay.tryPlacing(needed: false, refusedBefore: false, userChanged: true))
    }

    /// Where macOS once put it, meeting the user's display at its top-right
    /// corner: fine. A monitor added above the user's makes that a shared
    /// edge, and it has to move.
    func testAMonitorAddedAlongItMakesItMove() {
        let agent = at(1680, -1000)
        XCTAssertTrue(AgentDisplay.acceptable(agent, user: [user], others: [user]))
        let above = CGRect(x: 0, y: -1050, width: 1680, height: 1050)
        XCTAssertTrue(AgentDisplay.needsPlacing(agent, wanted: CGPoint(x: 1680, y: 1050), userChanged: true,
                                                user: [user, above], others: [user, above]))
        XCTAssertTrue(AgentDisplay.needsPlacing(agent, wanted: agent.origin, userChanged: true,
                                                user: [user, above], others: [user, above]))
    }

    // MARK: Which spares can go

    /// The staircase: the far one can go; the near one only with it.
    func testSparesGoFromTheFarEnd() {
        let rects = [user, at(1680, 1050), at(3280, 2050)]
        XCTAssertEqual(AgentDisplay.removable([1], rects: rects, roots: [0]), [])
        XCTAssertEqual(AgentDisplay.removable([2], rects: rects, roots: [0]), [2])
        XCTAssertEqual(AgentDisplay.removable([1, 2], rects: rects, roots: [0]), [1, 2])
    }

    /// Out of slot order (display 2 next to the user's, display 1 after
    /// it): display 2, spare, still holds display 1 up, in use.
    func testASpareHoldingUpAnotherIsKeptWhateverItsSlot() {
        let rects = [user, at(1680, 1050) /* slot 2, spare */, at(3280, 2050) /* slot 1, in use */]
        XCTAssertEqual(AgentDisplay.removable([1], rects: rects, roots: [0]), [])
    }

    /// Nor one another app's display hangs off: that one would move.
    func testASpareHoldingUpAnotherAppsDisplayIsKept() {
        let rects = [user, at(1680, 1050), at(3280, 2050) /* another app's */]
        XCTAssertEqual(AgentDisplay.removable([1], rects: rects, roots: [0]), [])
    }

    /// One the others don't need (both touch the user's) can go.
    func testASpareNothingHangsOffCanGo() {
        let rects = [user, at(1680, 1050), at(-1600, -1000)]
        XCTAssertEqual(AgentDisplay.removable([1], rects: rects, roots: [0]), [1])
    }

    // MARK: MoveBudget

    func testMovesAreBounded() {
        var b = AgentDisplay.MoveBudget()
        for i in 0..<4 { XCTAssertTrue(b.take(nowMs: Double(i) * 1000)) }
        XCTAssertFalse(b.take(nowMs: 4000))
        XCTAssertFalse(b.take(nowMs: 20_000))
        XCTAssertTrue(b.take(nowMs: 34_001))
    }

    func testSpreadOutMovesAreNotLimited() {
        var b = AgentDisplay.MoveBudget()
        for i in 0..<20 { XCTAssertTrue(b.take(nowMs: Double(i) * 3000)) }
    }

    // MARK: The fight

    /// A model of #110: two agent displays and another app's display placed
    /// like BCU used to place its own, at the corner of the rightmost
    /// display that isn't its app's, again after every change. Each round,
    /// every display that wants to move does. The old rule (agent displays
    /// placed by every display that isn't BCU's, moved whenever not at
    /// that spot) never settles; the new one doesn't move at all.
    func testAnotherAppPlacingAfterTheLastDisplaySettles() {
        func corner(_ rects: [CGRect]) -> CGPoint { AgentDisplay.corner(of: rects)! }
        func run(old: Bool) -> (bcuMoves: Int, theirMoves: Int) {
            var a1 = at(1680, 1050), a2 = at(3280, 2050)
            var theirs = at(-1600, 0)
            var bcuMoves = 0, theirMoves = 0
            for _ in 0..<40 {
                // The other app.
                let t = corner([user, a1, a2])
                if theirs.origin != t { theirs.origin = t; theirMoves += 1 }
                // BCU, display 1 then 2.
                let users = old ? [user, theirs] : [user]
                let w1 = old ? corner(users) : AgentDisplay.spot(size: size, preferred: corner(users), user: [user], others: [user, a2, theirs])
                let move1 = old ? a1.origin != w1
                    : AgentDisplay.needsPlacing(a1, wanted: w1, userChanged: false, user: [user], others: [user, a2, theirs])
                if move1 { a1.origin = w1; bcuMoves += 1 }
                let w2 = old ? CGPoint(x: a1.maxX, y: a1.maxY)
                    : AgentDisplay.spot(size: size, preferred: CGPoint(x: a1.maxX, y: a1.maxY), user: [user], others: [user, a1, theirs])
                let move2 = old ? a2.origin != w2
                    : AgentDisplay.needsPlacing(a2, wanted: w2, userChanged: false, user: [user], others: [user, a1, theirs])
                if move2 { a2.origin = w2; bcuMoves += 1 }
            }
            return (bcuMoves, theirMoves)
        }
        let old = run(old: true)
        XCTAssertGreaterThan(old.bcuMoves, 40, "the old rule chases the other app's display every round")
        let new = run(old: false)
        XCTAssertEqual(new.bcuMoves, 0)
        XCTAssertEqual(new.theirMoves, 1)
    }
}
