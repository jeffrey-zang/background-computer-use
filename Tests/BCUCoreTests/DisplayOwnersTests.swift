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
        DisplayOwners.claim(905, as: owner)
        DisplayOwners.release(905)
        XCTAssertEqual(DisplayOwners.owner(of: 905), owner, "this process didn't make it")
        DisplayOwners.release(905, as: owner)
        XCTAssertNil(DisplayOwners.owner(of: 905))
    }

    func testTheRecordsAreInTheUsersTempDirectoryNotBCUHome() {
        XCTAssertTrue(saved.path.hasPrefix("/private/var/folders/") || saved.path.hasPrefix("/var/folders/"), saved.path)
        XCTAssertFalse(saved.path.hasPrefix(BCUPaths.supportDirectory.path))
    }
}
