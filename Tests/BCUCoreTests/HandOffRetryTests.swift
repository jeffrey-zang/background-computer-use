import XCTest
@testable import BCUCore

/// After a step in an app the user isn't in, key goes to the user's window
/// there (`KeyScope.handOff`). It used to be one try with records 5 ms
/// apart, which on macOS 27 browsers left key on the agent's window about
/// half the time (`GiveBackRecordsTests`), with no second try: the user's
/// window then had no key until they came to the app (issue #87, 40 times
/// in a week: "swap: COULD NOT hand key to the user's window").
final class HandOffRetryTests: XCTestCase {
    /// An app that only moves key when the defocus record is handled before
    /// the focus record arrives, as measured with Helium: 40 ms apart works.
    private func slowApp(_ settle: Double) -> Bool { settle >= 40 }

    func testHandOffReachesAnAppThatNeedsTimeBetweenRecords() {
        var tries: [Double] = []
        let ok = KeyScope.tryInTurn(KeyScope.handOffSettles) { settle in
            tries.append(settle)
            return slowApp(settle)
        }
        XCTAssertTrue(ok, "key stayed on the agent's window after tries \(tries)")
    }

    /// An app that misses the first try (busy, say) gets a second.
    func testHandOffTriesAgainWhenTheFirstTryMisses() {
        var calls = 0
        let ok = KeyScope.tryInTurn(KeyScope.handOffSettles) { _ in
            calls += 1
            return calls == 2
        }
        XCTAssertTrue(ok)
        XCTAssertGreaterThanOrEqual(KeyScope.handOffSettles.count, 2)
    }

    func testHandOffStopsAtTheFirstTryThatWorks() {
        var calls = 0
        XCTAssertTrue(KeyScope.tryInTurn(KeyScope.handOffSettles) { _ in calls += 1; return true })
        XCTAssertEqual(calls, 1)
    }

    // MARK: Later tries

    func testALaterTryRunsWhileKeyIsStillOnTheAgentsWindow() {
        XCTAssertTrue(KeyScope.shouldRetryHandOff(appFront: false, swapping: false, parked: false, key: 7, agentKey: 7, userWindowExists: true))
    }

    /// The user came to the app: the guard's arrival handling moves key.
    func testNoLaterTryOnceTheUserIsInTheApp() {
        XCTAssertFalse(KeyScope.shouldRetryHandOff(appFront: true, swapping: false, parked: false, key: 7, agentKey: 7, userWindowExists: true))
    }

    /// Another step has key now, or parked it: leave it alone.
    func testNoLaterTryOverAnotherStep() {
        XCTAssertFalse(KeyScope.shouldRetryHandOff(appFront: false, swapping: true, parked: false, key: 7, agentKey: 7, userWindowExists: true))
        XCTAssertFalse(KeyScope.shouldRetryHandOff(appFront: false, swapping: false, parked: true, key: 7, agentKey: 7, userWindowExists: true))
    }

    /// The records landed late, or key moved some other way.
    func testNoLaterTryOnceKeyHasMoved() {
        XCTAssertFalse(KeyScope.shouldRetryHandOff(appFront: false, swapping: false, parked: false, key: 9, agentKey: 7, userWindowExists: true))
        XCTAssertFalse(KeyScope.shouldRetryHandOff(appFront: false, swapping: false, parked: false, key: 7, agentKey: 7, userWindowExists: false))
    }

    // MARK: Later tries run as a swap (review of #90)

    /// The records of a later try are sent inside the guard's swap, so a
    /// click on the app meanwhile is held rather than undone by them.
    func testALaterTryRunsInsideASwap() {
        var events: [String] = []
        let outcome = KeyScope.deferredHandOff(
            swapping: { false }, beginSwap: { events.append("begin") }, endSwap: { events.append("end") },
            shouldRetry: { events.append("check"); return true },
            attempt: { events.append("records"); return true })
        XCTAssertEqual(outcome, .handed)
        XCTAssertEqual(events, ["begin", "check", "records", "end"])
    }

    /// Whether to send anything is decided once the swap has begun: a click
    /// just before it (the app came forward, key moved) means nothing is sent.
    func testALaterTryChecksAfterTheSwapBegins() {
        var events: [String] = []
        let outcome = KeyScope.deferredHandOff(
            swapping: { false }, beginSwap: { events.append("begin") }, endSwap: { events.append("end") },
            shouldRetry: { events.append("check"); return false },
            attempt: { events.append("records"); return true })
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(events, ["begin", "check", "end"])
    }

    /// A step already swapping in the app goes first; no swap is begun.
    func testALaterTryIsSkippedWhileAStepSwaps() {
        var began = false
        let outcome = KeyScope.deferredHandOff(
            swapping: { true }, beginSwap: { began = true }, endSwap: {},
            shouldRetry: { true }, attempt: { XCTFail("records sent mid-swap"); return true })
        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(began)
    }

    func testAMissedTryEndsTheSwapToo() {
        var ended = false
        XCTAssertEqual(KeyScope.deferredHandOff(swapping: { false }, beginSwap: {}, endSwap: { ended = true },
                                                shouldRetry: { true }, attempt: { false }), .missed)
        XCTAssertTrue(ended)
    }

    /// The catalog's `guard_report` is still dispatched and read-only (review of #90).
    func testGuardReportKeepsItsCatalogName() {
        XCTAssertTrue(Engine.readOnlyTools.contains("guard_report"))
        XCTAssertFalse(Engine.readOnlyTools.contains("fgreport"))
    }
}
