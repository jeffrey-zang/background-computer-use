import XCTest
@testable import BCUCore

/// Where the agent display is anchored, and waiting on the main thread while BCU quits.
final class DisplayLifecycleTests: XCTestCase {
    override func tearDown() {
        Quitting.resetForTests()
        super.tearDown()
    }

    /// One display: its bottom-right corner, as before.
    func testOneDisplaysCorner() {
        XCTAssertEqual(AgentDisplay.corner(of: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), CGPoint(x: 1512, y: 982))
    }

    /// A tall display on the left and a short one on the right: the corner
    /// of their bounding box touches neither, so the short one's is used.
    func testUnevenDisplaysUseARealCorner() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 1500)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        XCTAssertEqual(AgentDisplay.corner(of: [left, right]), CGPoint(x: 2000, y: 800))
    }

    /// Two that end as far right (stacked): the lower one's corner.
    func testStackedDisplaysUseTheLowerOne() {
        let top = CGRect(x: 0, y: -900, width: 1440, height: 900)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(AgentDisplay.corner(of: [top, main]), CGPoint(x: 1440, y: 900))
    }

    /// Making a virtual display rearranges every display, and macOS waits
    /// (up to 0.25 s) for each app's main thread to hear of it, BCU's
    /// included. Made on BCU's main thread, macOS waits on a thread that's
    /// stuck in the very call, and every display add stalls for the whole
    /// wait. The stand-in does what macOS does: tells the main thread and
    /// waits up to 0.25 s for it to answer.
    func testTheDisplayIsMadeWithTheMainThreadFree() {
        let answered = Locked<[Bool]>([])
        let saved = AgentDisplay.makeVirtualDisplay
        defer { AgentDisplay.makeVirtualDisplay = saved }
        AgentDisplay.makeVirtualDisplay = { _, _, _, _ in
            let heard = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { heard.signal() }
            let ok = heard.wait(timeout: .now() + 0.25) == .success
            answered.mutate { $0.append(ok) }
            return nil
        }
        func onMain(_ work: @escaping () -> Void) throws {
            guard onMainUnlessQuitting(work) else { throw ToolError("quitting") }
        }
        let display = AgentDisplay()
        let threw = Locked(false)
        let done = expectation(description: "open returned")
        DispatchQueue.global().async {
            do { try display.open(onMain: onMain) } catch { threw.value = true }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(threw.value, "no display was made, so opening it fails")
        XCTAssertFalse(answered.value.isEmpty)
        XCTAssertEqual(answered.value.filter { !$0 }.count, 0, "made \(answered.value.count) times; the main thread didn't answer in 0.25 s \(answered.value.filter { !$0 }.count) times")
    }

    func testNoDisplayNoCorner() {
        XCTAssertNil(AgentDisplay.corner(of: []))
        XCTAssertNil(AgentDisplay.corner(of: [.null]))
    }

    /// Off the main thread, the work runs there and is waited for.
    func testRunsOnMainAndWaits() {
        let ran = Locked(false)
        let done = expectation(description: "returned")
        DispatchQueue.global().async {
            let ok = onMainUnlessQuitting { ran.value = Thread.isMainThread }
            XCTAssertTrue(ok)
            XCTAssertTrue(ran.value)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// The main thread is busy (as in `Hub.shutdown`) when BCU starts
    /// quitting: the waiter gives up instead of waiting for it, and the
    /// work never runs.
    func testGivesUpWhenQuittingWhileMainIsBusy() {
        let ran = Locked(false)
        let result = Locked<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.value = onMainUnlessQuitting { ran.value = true }
            done.signal()
        }
        // This thread is main, and doesn't run its queue while it waits here.
        XCTAssertEqual(done.wait(timeout: .now() + 0.2), .timedOut)
        Quitting.begin()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.value, false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ran.value)
    }
}
