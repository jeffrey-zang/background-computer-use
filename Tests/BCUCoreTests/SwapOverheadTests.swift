import XCTest
@testable import BCUCore

/// The fixed cost of a key swap with the user in the same app (#87): what
/// the user's window waits for besides the step itself.
final class SwapOverheadTests: XCTestCase {
    // MARK: Gaps between records when giving key back

    func testAppKitAppsGetKeyBackWithShortGaps() {
        XCTAssertEqual(KeyScope.giveBackSettle(chromium: false), 5)
        XCTAssertLessThan(KeyScope.giveBackSettle(chromium: false), KeyScope.giveBackSettleMs)
    }

    func testChromiumKeepsItsLongerGaps() {
        XCTAssertEqual(KeyScope.giveBackSettle(chromium: true), KeyScope.giveBackSettleMs)
        XCTAssertGreaterThanOrEqual(KeyScope.giveBackSettle(chromium: true), 40)
    }

    func testChromiumIsToldByItsBundledFramework() {
        XCTAssertTrue(AppKind.isChromium(frameworks: ["Google Chrome Framework.framework"]))
        XCTAssertTrue(AppKind.isChromium(frameworks: ["Squirrel.framework", "Electron Framework.framework"]))
        XCTAssertTrue(AppKind.isChromium(frameworks: ["Chromium Embedded Framework.framework"]))
        XCTAssertFalse(AppKind.isChromium(frameworks: []))
        XCTAssertFalse(AppKind.isChromium(frameworks: ["Sparkle.framework", "WebKit.framework"]))
    }

    func testChromiumByBundleOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appkind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let chrome = dir.appendingPathComponent("Fake Chrome.app")
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Contents/Frameworks/Fake Chrome Framework.framework"), withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        XCTAssertTrue(AppKind.isChromium(bundle: chrome))
        XCTAssertFalse(AppKind.isChromium(bundle: plain))
    }

    // MARK: Where key goes back to

    private let agent: CGWindowID = 900
    private func onAgent(_ id: CGWindowID) -> Bool { id >= 900 }

    func testKeyGoesBackToTheWindowThatHasItInAnActiveApp() {
        // The batch's cover says 51, but the user is in 52 now.
        XCTAssertEqual(KeyScope.giveBackWindow(user: 51, current: 52, active: true, ours: [agent], onAgentDisplay: onAgent), 52)
    }

    func testAStaleOrAgentKeyWindowDefersToTheUsersWindow() {
        // Inactive app: AXFocusedWindow can be stale.
        XCTAssertEqual(KeyScope.giveBackWindow(user: 51, current: 52, active: false, ours: [agent], onAgentDisplay: onAgent), 51)
        // Key on the agent's own window, or on another agent's.
        XCTAssertEqual(KeyScope.giveBackWindow(user: 51, current: agent, active: true, ours: [agent], onAgentDisplay: onAgent), 51)
        XCTAssertEqual(KeyScope.giveBackWindow(user: 51, current: 950, active: true, ours: [agent], onAgentDisplay: onAgent), 51)
        // Nothing known.
        XCTAssertEqual(KeyScope.giveBackWindow(user: 51, current: nil, active: true, ours: [agent], onAgentDisplay: onAgent), 51)
        XCTAssertEqual(KeyScope.giveBackWindow(user: nil, current: agent, active: false, ours: [agent], onAgentDisplay: onAgent), agent)
    }

    func testKeyBackOutcomes() {
        XCTAssertEqual(KeyScope.keyBack(key: 51, previous: 51, ours: [agent], onAgentDisplay: onAgent), .back)
        XCTAssertEqual(KeyScope.keyBack(key: agent, previous: 51, ours: [agent], onAgentDisplay: onAgent), .ours)
        XCTAssertEqual(KeyScope.keyBack(key: nil, previous: 51, ours: [agent], onAgentDisplay: onAgent), .ours)
        // Another agent's window on an agent display is not the user's.
        XCTAssertEqual(KeyScope.keyBack(key: 950, previous: 51, ours: [agent], onAgentDisplay: onAgent), .ours)
        // Another of the user's windows: key is off the agent's.
        XCTAssertEqual(KeyScope.keyBack(key: 52, previous: 51, ours: [agent], onAgentDisplay: onAgent), .elsewhere(52))
    }

    func testKeyOnAnotherWindowCountsOnlyOnceSettledEvenPastTheBudget() {
        let settle = KeyScope.elsewhereSettleMs
        // Seen 2 ms before the deadline, then the deadline passes: keep looking.
        XCTAssertNil(KeyScope.keyBackStep(state: .elsewhere(52), elsewhereForMs: 2, now: 1001, deadline: 1000))
        // Settled: that's where key went.
        XCTAssertEqual(KeyScope.keyBackStep(state: .elsewhere(52), elsewhereForMs: settle, now: 1000 + settle, deadline: 1000), .elsewhere(52))
        // Still not settled one settle-interval past the deadline (it kept moving): not confirmed.
        XCTAssertEqual(KeyScope.keyBackStep(state: .elsewhere(53), elsewhereForMs: 5, now: 1000 + settle, deadline: 1000), .ours)
        // Back, or still ours.
        XCTAssertEqual(KeyScope.keyBackStep(state: .back, elsewhereForMs: nil, now: 10, deadline: 1000), .back)
        XCTAssertNil(KeyScope.keyBackStep(state: .ours, elsewhereForMs: nil, now: 10, deadline: 1000))
        XCTAssertEqual(KeyScope.keyBackStep(state: .ours, elsewhereForMs: nil, now: 1000, deadline: 1000), .ours)
    }

    func testAMomentOnAnotherWindowIsNotTakenForWhereKeyWent() {
        // The defocus record alone can pass key on for a moment.
        XCTAssertGreaterThanOrEqual(KeyScope.elsewhereSettleMs, 40)
        XCTAssertLessThan(KeyScope.elsewhereSettleMs, 250)
    }
}
