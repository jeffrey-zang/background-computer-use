import XCTest
import ApplicationServices
@testable import BCUCore

/// #113: other computer-use tools can screenshot the agent display and read
/// or change the agent's windows through Accessibility. BCU covers the
/// display against screenshots of it (`PrivacyCover`) and reports changes
/// to the agent's windows it didn't make (`InterferenceWatch`).
final class DisplayPrivacyTests: XCTestCase {
    private let value = kAXValueChangedNotification as String
    private let focus = kAXFocusedUIElementChangedNotification as String

    // MARK: What counts as interference

    func testAnotherToolSettingATextAreaWhileTheAgentIsIdleIsReported() {
        let what = InterferenceWatch.describe(notification: value, role: "AXTextArea", subrole: nil, title: nil,
                                              value: "Overwritten by another agent", idleMs: 5000, appIsFront: false, withUser: false)
        XCTAssertEqual(what, "a text area's value was changed to \"Overwritten by another agent\"")
    }

    /// BCU's own steps (and the app answering them a moment later) aren't interference.
    func testChangesDuringOrJustAfterTheAgentsOwnCallAreNotReported() {
        XCTAssertNil(InterferenceWatch.describe(notification: value, role: "AXTextArea", subrole: nil, title: nil,
                                                value: "x", idleMs: 0, appIsFront: false, withUser: false))
        XCTAssertNil(InterferenceWatch.describe(notification: value, role: "AXTextArea", subrole: nil, title: nil,
                                                value: "x", idleMs: InterferenceWatch.graceMs - 1, appIsFront: false, withUser: false))
        XCTAssertNotNil(InterferenceWatch.describe(notification: value, role: "AXTextArea", subrole: nil, title: nil,
                                                   value: "x", idleMs: InterferenceWatch.graceMs, appIsFront: false, withUser: false))
    }

    /// A window the user took over (handoff, or driving the display) changes because of them.
    func testChangesWhileTheUserHasTheWindowAreNotReported() {
        XCTAssertNil(InterferenceWatch.describe(notification: value, role: "AXTextField", subrole: nil, title: nil,
                                                value: "x", idleMs: 9000, appIsFront: false, withUser: true))
    }

    /// Text a page shows, timers and progress bars change by themselves.
    func testValueChangesOutsideInputControlsAreNotReported() {
        for role in ["AXStaticText", "AXProgressIndicator", "AXWebArea", "AXGroup"] {
            XCTAssertNil(InterferenceWatch.describe(notification: value, role: role, subrole: nil, title: nil,
                                                    value: "x", idleMs: 9000, appIsFront: false, withUser: false), role)
        }
    }

    func testPasswordValuesAreNeverQuoted() {
        let what = InterferenceWatch.describe(notification: value, role: "AXSecureTextField", subrole: nil, title: "Password",
                                              value: "hunter2", idleMs: 9000, appIsFront: false, withUser: false)
        XCTAssertEqual(what, "a password field \"Password\"'s value was changed")
    }

    /// Some apps mark a password field only by its subrole.
    func testPasswordValuesAreNeverQuotedWhenOnlyTheSubroleSaysSo() {
        let what = InterferenceWatch.describe(notification: value, role: "AXTextField", subrole: "AXSecureTextField", title: "Password",
                                              value: "hunter2", idleMs: 9000, appIsFront: false, withUser: false)
        XCTAssertEqual(what, "a password field \"Password\"'s value was changed")
        XCTAssertFalse(what?.contains("hunter2") == true)
    }

    /// The guard report is shared by every session in the engine: what goes
    /// there leaves the value out (the session's own step result keeps it).
    func testTheSharedSummaryLeavesTheValueOut() {
        let shared = InterferenceWatch.describe(notification: value, role: "AXTextArea", subrole: nil, title: nil,
                                                value: nil, idleMs: 9000, appIsFront: false, withUser: false)
        XCTAssertEqual(shared, "a text area's value was changed")
    }

    /// In the app the user is in, their own clicks and keys move focus.
    func testFocusMovesAreReportedOnlyWhenTheUserIsntInThatApp() {
        XCTAssertEqual(InterferenceWatch.describe(notification: focus, role: "AXButton", subrole: nil, title: "Send",
                                                  value: nil, idleMs: 9000, appIsFront: false, withUser: false),
                       "focus was moved to a button \"Send\"")
        XCTAssertNil(InterferenceWatch.describe(notification: focus, role: "AXButton", subrole: nil, title: "Send",
                                                value: nil, idleMs: 9000, appIsFront: true, withUser: false))
    }

    func testLongValuesAreClippedToOneLine() {
        let what = InterferenceWatch.describe(notification: value, role: "AXTextArea", subrole: nil, title: nil,
                                              value: String(repeating: "a", count: 50) + "\n" + String(repeating: "b", count: 100),
                                              idleMs: 9000, appIsFront: false, withUser: false)!
        XCTAssertFalse(what.contains("\n"))
        XCTAssertTrue(what.hasSuffix("…\""))
    }

    // MARK: Reporting

    /// One write fires several notifications: the agent hears of it once, with the latest value.
    func testRepeatedNotificationsForOneElementAreCoalesced() {
        var l = InterferenceWatch.Ledger()
        l.add(.init(ms: 1000, window: 7, app: "TextEdit", what: "a text area's value was changed to \"O\"", key: "v|AXTextArea|1"))
        l.add(.init(ms: 1100, window: 7, app: "TextEdit", what: "a text area's value was changed to \"Overwritten\"", key: "v|AXTextArea|1"))
        l.add(.init(ms: 1200, window: 7, app: "TextEdit", what: "focus was moved to a text area", key: "f|AXTextArea|1"))
        l.add(.init(ms: 9000, window: 7, app: "TextEdit", what: "a text area's value was changed to \"Again\"", key: "v|AXTextArea|1"))
        let taken = l.take()
        XCTAssertEqual(taken.map(\.what), ["a text area's value was changed to \"Overwritten\"", "focus was moved to a text area",
                                           "a text area's value was changed to \"Again\""])
        XCTAssertTrue(l.take().isEmpty, "each change is reported once")
    }

    func testTheReportNamesTheWindowAndWhatToDo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = InterferenceWatch.report([.init(ms: 10_000, window: 42, app: "TextEdit", what: "a text area's value was changed to \"x\"")],
                                            now: now, nowMs: 12_000)!
        XCTAssertTrue(text.contains("window 42 (TextEdit)"))
        XCTAssertTrue(text.contains("changed to \"x\""))
        XCTAssertTrue(text.contains("get_window_state"))
        XCTAssertNil(InterferenceWatch.report([]))
    }

    // MARK: The cover

    func testTheCoverSitsExactlyOverTheDisplay() {
        // A display left of a 1680x1050 main display, top-aligned.
        let f = PrivacyCover.cocoaFrame(CGRect(x: -1280, y: 0, width: 1280, height: 800), primaryHeight: 1050)
        XCTAssertEqual(f, NSRect(x: -1280, y: 250, width: 1280, height: 800))
    }

    /// Fully opaque would make WindowServer treat the windows under it as
    /// hidden, and apps stop drawing hidden windows. One 99.9% layer let
    /// enough through to read the agent's text after a contrast stretch.
    func testTheCoverIsNeverOpaqueButLetsLessThanAnEightBitStepThrough() {
        XCTAssertLessThan(PrivacyCover.alpha, 1)
        XCTAssertGreaterThan(PrivacyCover.layers, 1)
        // What shows through, at full contrast underneath, in 8-bit steps.
        XCTAssertLessThan(PrivacyCover.transmission * 255, 0.001)
        XCTAssertGreaterThan(PrivacyCover.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
    }

    /// A screen stream (recording, sharing, another tool's capture) is
    /// noted when it starts and ends; nothing in between.
    func testScreenStreamsAreNotedWhenTheyStartAndEnd() {
        XCTAssertTrue(StreamWatch.note(was: false, now: true, forMs: 0)?.hasPrefix("screen capture started") == true)
        XCTAssertEqual(StreamWatch.note(was: true, now: false, forMs: 5_400), "screen capture ended after 5 s")
        XCTAssertNil(StreamWatch.note(was: true, now: true, forMs: 1000))
        XCTAssertNil(StreamWatch.note(was: false, now: false, forMs: 0))
    }
}
