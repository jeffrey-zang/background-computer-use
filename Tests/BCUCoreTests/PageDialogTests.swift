import XCTest
@testable import BCUCore

/// A web page's own dialog in Safari (issue #108): which ones are a page
/// asking to leave, what an agent is told, and in which browsers steps are
/// watched for one.
final class PageDialogTests: XCTestCase {
    /// Safari's beforeunload dialog, as its accessibility lists it: the
    /// release of a window answers it the way Chromium's "Leave site?" is.
    func testSafarisLeavePageDialogIsALeaveDialog() {
        XCTAssertEqual(PageDialog.leaveButton(["Stay on Page", "Leave Page"]), "Leave Page")
        XCTAssertEqual(PageDialog.leaveButton(["Leave", "Cancel"]), "Leave")
    }

    /// alert, confirm and prompt aren't a page asking to leave: nothing
    /// answers them for the agent.
    func testAlertsConfirmsAndPromptsAreNotLeaveDialogs() {
        XCTAssertNil(PageDialog.leaveButton(["Close"]))
        XCTAssertNil(PageDialog.leaveButton(["Cancel", "OK"]))
        XCTAssertNil(PageDialog.leaveButton(["Leave Page"]))
        // A bigger dialog with those words in it is something else.
        XCTAssertNil(PageDialog.leaveButton(["Stay on Page", "Leave Page", "Help", "More", "Report"]))
    }

    /// Safari titles every page dialog "JavaScript": what the page asks is
    /// the rest, once.
    func testTheMessageIsWhatThePageAsks() {
        XCTAssertEqual(PageDialog.message(texts: ["JavaScript", "Are you sure you want to leave this page?"]),
                       "Are you sure you want to leave this page?")
        XCTAssertEqual(PageDialog.message(texts: ["JavaScript", "Delete the\ndraft?", "Delete the draft?"]), "Delete the draft?")
        XCTAssertEqual(PageDialog.message(texts: ["JavaScript"]), "")
    }

    /// A step that left the page asking says the page didn't go anywhere,
    /// rather than reading as success.
    func testAStepThatRaisedALeaveDialogSaysNothingLeft() {
        let note = PageDialog.stepNote(message: "Are you sure you want to leave this page?", buttons: ["Stay on Page", "Leave Page"], window: 42)
        XCTAssertTrue(note.hasPrefix("\n[page] The page in window 42 is asking \"Are you sure you want to leave this page?\" (Stay on Page / Leave Page)."))
        XCTAssertTrue(note.contains("Nothing has left or closed yet"))
        XCTAssertTrue(note.contains("get_window_state window_id=42 lists the dialog first"))
    }

    func testAStepThatRaisedAnAlertSaysThePageWaits() {
        let note = PageDialog.stepNote(message: "Delete the draft?", buttons: ["Cancel", "OK"], window: 7)
        XCTAssertTrue(note.contains("asking \"Delete the draft?\" (Cancel / OK). The page waits until it's answered."))
        XCTAssertFalse(note.contains("Nothing has left"))
    }

    /// The state's header names the dialog's buttons by number, so a read
    /// that lists only changes still says the page is waiting.
    func testTheStateLineNumbersTheButtons() {
        let line = PageDialog.stateLine(message: "Are you sure you want to leave this page?",
                                        buttons: [(index: 21, title: "Stay on Page"), (index: 22, title: "Leave Page")])
        XCTAssertEqual(line, "A dialog from the page is waiting for an answer \"Are you sure you want to leave this page?\": [21] Stay on Page, [22] Leave Page. The page takes no input until it's answered.")
    }

    /// Safari's steps are watched; Chromium's "Leave site?" is answered as it
    /// comes (`LeaveWatch`), and other apps aren't browsers.
    func testOnlySafarisStepsAreWatched() {
        XCTAssertTrue(PageDialog.watches(bundleID: "com.apple.Safari"))
        XCTAssertTrue(PageDialog.watches(bundleID: "com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(PageDialog.watches(bundleID: "com.google.Chrome"))
        XCTAssertFalse(PageDialog.watches(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(PageDialog.watches(bundleID: nil))
        XCTAssertTrue(PageDialog.watchedTools.isSuperset(of: ["click", "type_text", "press_key", "press_menu_item"]))
        XCTAssertFalse(PageDialog.watchedTools.contains("get_window_state"))
    }
}
