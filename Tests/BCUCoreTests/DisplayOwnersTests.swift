import XCTest
import CoreGraphics
import BCUShared
@testable import BCUCore

/// A BCU display another engine has open and running isn't a crashed
/// copy's leftover: its windows stay where they are (#95). One whose owner
/// has exited, or that nobody recorded, still has its windows rescued.
final class DisplayOwnersTests: XCTestCase {
    private var saved: URL!
    private var dir: URL!

    override func setUp() {
        saved = DisplayOwners.directory
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("display-owners-\(UUID().uuidString)")
        DisplayOwners.directory = dir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        DisplayOwners.directory = saved
    }

    private func otherEngine() throws -> (Process, DisplayOwners.Owner) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        let start = try XCTUnwrap(DisplayOwners.startTime(of: p.processIdentifier))
        return (p, DisplayOwners.Owner(pid: p.processIdentifier, start: start))
    }

    func testAnotherLiveEnginesDisplayIsNotRescued() throws {
        let (p, owner) = try otherEngine()
        defer { p.terminate() }
        DisplayOwners.claim(901, as: owner)
        XCTAssertEqual(DisplayOwners.liveOwner(of: 901), owner)
        XCTAssertEqual(AgentDisplay.orphaned([901, 902]), [902], "nobody recorded 902: a crashed copy's")
    }

    func testADisplayWhoseOwnerExitedIsRescued() throws {
        let (p, owner) = try otherEngine()
        DisplayOwners.claim(903, as: owner)
        p.terminate()
        p.waitUntilExit()
        XCTAssertNil(DisplayOwners.liveOwner(of: 903))
        XCTAssertEqual(AgentDisplay.orphaned([903]), [903])
    }

    func testAReusedProcessIDDoesNotCount() throws {
        let (p, owner) = try otherEngine()
        defer { p.terminate() }
        DisplayOwners.claim(904, as: DisplayOwners.Owner(pid: owner.pid, start: owner.start - 1))
        XCTAssertNil(DisplayOwners.liveOwner(of: 904))
    }

    func testOnlyTheOwnerRemovesTheRecord() throws {
        let (p, owner) = try otherEngine()
        defer { p.terminate() }
        let generation = DisplayOwners.claim(905, as: owner)
        DisplayOwners.release(905, generation: generation)
        XCTAssertEqual(DisplayOwners.owner(of: 905), owner, "this process didn't make it")
        DisplayOwners.release(905, generation: generation, as: owner)
        XCTAssertNil(DisplayOwners.owner(of: 905))
    }

    /// One session lets go of display 907 while another session of the
    /// same engine has been given 907 again and claimed it: the old
    /// release mustn't take the new claim's record.
    func testALateReleaseLeavesThisEnginesNewClaimOfTheSameID() {
        let old = DisplayOwners.claim(907)
        let new = DisplayOwners.claim(907)
        XCTAssertNotEqual(old, new)
        DisplayOwners.release(907, generation: old)
        XCTAssertEqual(DisplayOwners.record(of: 907)?.generation, new, "the replacement's record stays")
        XCTAssertEqual(DisplayOwners.owner(of: 907), DisplayOwners.me)
        DisplayOwners.release(907, generation: new)
        XCTAssertNil(DisplayOwners.owner(of: 907))
    }

    func testTheRecordsAreInTheUsersTempDirectoryNotBCUHome() {
        XCTAssertTrue(saved.path.hasPrefix("/private/var/folders/") || saved.path.hasPrefix("/var/folders/"), saved.path)
        XCTAssertFalse(saved.path.hasPrefix(BCUPaths.supportDirectory.path))
    }

    /// A claim waits while another engine holds the lock to check and
    /// delete a record, so it can't land between the two (the lock is a
    /// `flock`, which another open of the file, as another process's is,
    /// can't take at the same time).
    func testAClaimWaitsForARelease() throws {
        let (p, owner) = try otherEngine()
        defer { p.terminate() }
        DisplayOwners.claim(905)
        let held = expectation(description: "lock held")
        let done = expectation(description: "release done")
        DispatchQueue.global().async {
            DisplayOwners.withLock {
                held.fulfill()
                Thread.sleep(forTimeInterval: 0.3)
                if DisplayOwners.owner(of: 905) == DisplayOwners.me {
                    try? FileManager.default.removeItem(at: DisplayOwners.directory.appendingPathComponent("905"))
                }
            }
            done.fulfill()
        }
        wait(for: [held], timeout: 5)
        let t0 = Date()
        DisplayOwners.claim(905, as: owner)
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.2, "the claim waited for the lock")
        wait(for: [done], timeout: 5)
        XCTAssertEqual(DisplayOwners.owner(of: 905), owner, "the new owner's record survives the old owner's release")
    }
}
