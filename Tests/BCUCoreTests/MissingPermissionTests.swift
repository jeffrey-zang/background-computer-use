import XCTest
@testable import BCUCore

/// Issue #88: an engine without Accessibility read no "New Window" menu
/// item, so open_window said Safari "may not support multiple windows" and
/// sent the agent to borrow_window, which can't work without it either.
/// It now refuses up front and names the permission and who needs it.
final class MissingPermissionTests: XCTestCase {
    let host = "Host App (/Applications/Host App.app)"

    func testOpeningWithoutAccessibilityNamesThePermissionAndProcess() throws {
        for tool in ["open_window", "borrow_window"] {
            let text = try XCTUnwrap(Engine.permissionRefusal(tool: tool, accessibility: false, screenRecording: true, process: host), tool)
            XCTAssertTrue(text.contains("Accessibility permission is missing for \(host)"), text)
            XCTAssertTrue(text.contains("Privacy & Security > Accessibility"), text)
            XCTAssertFalse(text.contains("may not support multiple windows"), text)
            XCTAssertFalse(text.contains("Screen Recording"), text)
            XCTAssertEqual(text.contains("Don't try borrow_window"), tool == "open_window", text)
        }
    }

    func testBothMissingNamesBoth() throws {
        let text = try XCTUnwrap(Engine.permissionRefusal(tool: "open_window", accessibility: false, screenRecording: false, process: host))
        XCTAssertTrue(text.contains("Accessibility and Screen Recording permissions are missing"), text)
    }

    func testGrantedOrOtherToolsAreNotRefused() {
        XCTAssertNil(Engine.permissionRefusal(tool: "open_window", accessibility: true, screenRecording: false, process: host))
        XCTAssertNil(Engine.permissionRefusal(tool: "borrow_window", accessibility: true, screenRecording: true, process: host))
        for tool in ["status", "list_apps", "list_windows"] {
            XCTAssertNil(Engine.permissionRefusal(tool: tool, accessibility: false, screenRecording: false, process: host), tool)
        }
    }

    func testPermissionHolderIsThisProcess() {
        XCTAssertFalse(Engine.permissionHolder.isEmpty)
    }
}
