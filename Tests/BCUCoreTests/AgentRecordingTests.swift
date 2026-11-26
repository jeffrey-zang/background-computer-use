import XCTest
import AVFoundation
@testable import BCUCore
@testable import BCUShared

/// start_recording / stop_recording (#114): what each step's caption says,
/// what the action list holds (one entry per tool call, failures and
/// batch steps included), what's hidden, and how the marks are timed.
final class AgentRecordingTests: XCTestCase {
    private func clock() -> (() -> Double, (Double) -> Void) {
        var now = 0.0
        return ({ now }, { now = $0 })
    }

    // MARK: Captions

    func testCaptionsNameTheTarget() {
        let reload = StepTarget(element: 26, role: "AXButton", label: "Reload this page", frame: .zero, secure: false)
        XCTAssertEqual(RecordingText.caption(tool: "click", args: ["element": 26], target: reload, hidden: false), "click \"Reload this page\" (Button)")
        XCTAssertEqual(RecordingText.caption(tool: "click", args: ["element": 26, "count": 2], target: reload, hidden: false), "double-click \"Reload this page\" (Button)")
        XCTAssertEqual(RecordingText.caption(tool: "click", args: ["x": 10.4, "y": 20], target: nil, hidden: false), "click at (10, 20)")
        let unnamed = StepTarget(element: 7, role: "AXCheckBox", label: "", frame: .zero, secure: false)
        XCTAssertEqual(RecordingText.caption(tool: "click", args: ["element": 7], target: unnamed, hidden: false), "click element 7 (CheckBox)")
        let email = StepTarget(element: 3, role: "AXTextField", label: "Email", frame: .zero, secure: false)
        XCTAssertEqual(RecordingText.caption(tool: "type_text", args: ["text": "hello@example.com", "element": 3], target: email, hidden: false),
                       "type_text \"hello@example.com\" into \"Email\" (TextField)")
        XCTAssertEqual(RecordingText.caption(tool: "set_value", args: ["value": "14", "element": 3], target: email, hidden: false),
                       "set_value \"Email\" (TextField) = \"14\"")
        XCTAssertEqual(RecordingText.caption(tool: "press_key", args: ["key": "l", "modifiers": ["cmd"]], target: nil, hidden: false), "press_key ⌘L")
        XCTAssertEqual(RecordingText.caption(tool: "navigate", args: ["url": "https://example.com/a"], target: nil, hidden: false), "navigate example.com/a")
        XCTAssertEqual(RecordingText.caption(tool: "scroll", args: ["dy": 3], target: nil, hidden: false), "scroll down 3")
        XCTAssertEqual(RecordingText.caption(tool: "batch", args: ["actions": 3], target: nil, hidden: false), "batch of 3 actions")
    }

    func testHiddenTextIsNeverInTheCaption() {
        let pw = StepTarget(element: 5, role: "AXTextField", label: "Password", frame: .zero, secure: true)
        let c = RecordingText.caption(tool: "type_text", args: ["text": "hunter2"], target: pw, hidden: true)
        XCTAssertFalse(c.contains("hunter2"))
        XCTAssertEqual(c, "type_text (hidden, 7 characters) into \"Password\" (TextField)")
    }

    func testKeycapsPutModifiersInMacOrder() {
        XCTAssertEqual(RecordingText.keycaps(key: "z", modifiers: ["cmd", "shift"]), ["⇧", "⌘", "Z"])
        XCTAssertEqual(RecordingText.keycaps(key: "return", modifiers: []), ["⏎"])
        XCTAssertEqual(RecordingText.keycaps(key: "tab", modifiers: ["ctrl"]), ["⌃", "⇥"])
    }

    func testOutcomePicksTheFailedStep() {
        XCTAssertEqual(RecordingText.outcome("1. click: Pressed.\n2. click FAILED: element 9 isn't there\nStopped; …", isError: true), "2. click FAILED: element 9 isn't there")
        XCTAssertEqual(RecordingText.outcome("Pressed element 26 (AXButton) through accessibility.\n[focus guard] x", isError: false),
                       "Pressed element 26 (AXButton) through accessibility.")
        XCTAssertEqual(RecordingText.waits(in: "done\n[user first] Waited 1.4 s for you to pause."), ["[user first] Waited 1.4 s for you to pause."])
    }

    // MARK: The step list

    func testBatchStepsGoUnderTheirBatch() {
        let (now, set) = clock()
        let log = StepLog(redactAll: false, clock: now)
        let a = log.begin(tool: "get_window_state", args: ["window_id": 1])
        log.end(a, result: "Window 1", isError: false)
        set(1000)
        let b = log.begin(tool: "batch", args: ["window_id": 1, "actions": [["tool": "click", "element": 2], ["tool": "wait"]], "_session": "x"])
        let b1 = log.begin(tool: "click", args: ["element": 2], inBatch: true)
        log.setPoint(CGPoint(x: 10, y: 20), click: true)
        log.setPoint(CGPoint(x: 99, y: 99), click: false)  // a move after the click doesn't replace it
        set(1200)
        log.end(b1, result: "Pressed", isError: false)
        let b2 = log.begin(tool: "wait", args: ["ms": 10], inBatch: true)
        log.end(b2, result: "Waited 10 ms.", isError: false)
        log.end(b, result: "1. click: Pressed\n2. wait: 10 ms", isError: false)
        XCTAssertEqual(log.all.map(\.tool), ["get_window_state", "batch"])
        XCTAssertEqual(log.all[1].steps.map(\.number), ["2.1", "2.2"])
        XCTAssertEqual(log.all[1].args["actions"] as? Int, 2, "a batch keeps how many steps, not their arguments")
        XCTAssertNil(log.all[1].args["_session"])
        XCTAssertEqual(b1.point, CGPoint(x: 10, y: 20))
        XCTAssertTrue(b1.clicked)
        XCTAssertEqual(b1.durationMs, 200)
        XCTAssertEqual(StepLog.flatten(log.all).map(\.number), ["1", "2", "2.1", "2.2"])
    }

    func testSecretsLeaveArgsAndResults() {
        let log = StepLog(redactAll: false, clock: { 0 })
        let b = log.begin(tool: "batch", args: ["actions": [["tool": "set_value", "value": "hunter2"]]])
        let s = log.begin(tool: "set_value", args: ["element": 5, "value": "hunter2"], inBatch: true)
        log.setTarget(StepTarget(element: 5, role: "AXTextField", label: "Password", frame: .zero, secure: true))
        log.end(s, result: "Set element 5 to \"hunter2\" (verified).", isError: false)
        log.end(b, result: "1. set_value: Set element 5 to \"hunter2\" (verified).", isError: false)
        let t = log.begin(tool: "type_text", args: ["text": "s3cret!"])
        log.setFocusSecure()
        log.end(t, result: "Typed 7 characters with keystrokes.", isError: false)
        let plain = log.begin(tool: "type_text", args: ["text": "hello"])
        log.setFocus(secure: false)
        log.end(plain, result: "Typed 5 characters.", isError: false)
        let info = ActionList.Info(started: Date(), durationMs: 1000, source: "display", windowID: nil, fps: 12, frames: 12,
                                   size: CGSize(width: 1600, height: 1000), label: "Agent", redactAll: false, video: "recording.mp4")
        let md = ActionList.markdown(log.all, info: info)
        let json = String(decoding: ActionList.json(log.all, info: info), as: UTF8.self)
        for text in [md, json] {
            XCTAssertFalse(text.contains("hunter2"), text)
            XCTAssertFalse(text.contains("s3cret"), text)
            XCTAssertTrue(text.contains("hello"), "text typed into an ordinary field is shown")
        }
        XCTAssertNil(s.secret)
        XCTAssertEqual(RecordingText.caption(tool: s.tool, args: s.args, target: s.target, hidden: true),
                       "set_value \"Password\" (TextField) = (hidden, 7 characters)", "the count is the secret's, not the placeholder's")
    }

    /// Typing that stops partway quotes what went in: none of it shows.
    func testAPartialSecretInAnErrorIsHidden() {
        let log = StepLog(redactAll: false, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "hunter2", "element": 5])
        log.setTarget(StepTarget(element: 5, role: "AXTextField", label: "Password", frame: .zero, secure: true))
        log.end(t, result: "stopped typing: Typed 4 of 7 characters (\"hunt\"), nothing after that.", isError: true)
        XCTAssertFalse(t.result.contains("hunt"), t.result)
        let b = log.begin(tool: "batch", args: [:])
        let b1 = log.begin(tool: "click", args: ["element": 2], inBatch: true)
        log.end(b1, result: "Clicked \"Log in\"", isError: false)
        let b2 = log.begin(tool: "type_text", args: ["text": "s3cret", "element": 5], inBatch: true)
        log.setFocusSecure()
        log.end(b2, result: "Typed 2 of 6 characters (\"s3\")", isError: true)
        log.end(b, result: "1. click: Clicked \"Log in\"\n2. type_text FAILED: Typed 2 of 6 characters (\"s3\")", isError: true)
        XCTAssertFalse(b.result.contains("\"s3\""), b.result)
        XCTAssertTrue(b.result.contains("\"Log in\""), "other steps' lines are left as they are")
        XCTAssertEqual(RecordingText.hideQuoted("a \"x\" b \"y\""), "a \"(hidden)\"")
        // Typed text can hold quotes itself.
        XCTAssertEqual(RecordingText.hideQuoted("Typed 7 of 10 characters (\"abc\"def\"), nothing after that."),
                       "Typed 7 of 10 characters (\"(hidden)\"), nothing after that.")
    }

    /// A call answered off the session's queue (status, from another
    /// connection) while an action runs doesn't take the action's target.
    func testAnOffQueueCallDoesntTakeTheActionsTarget() {
        let log = StepLog(redactAll: false, clock: { 0 })
        let a = log.begin(tool: "type_text", args: ["text": "pw", "element": 5])
        let st = log.begin(tool: "status", args: [:], tracked: false)
        log.setTarget(StepTarget(element: 5, role: "AXTextField", label: "Password", frame: .zero, secure: true))
        log.setFocusSecure()
        log.end(st, result: "ok", isError: false)
        log.end(a, result: "Typed 2 characters", isError: false)
        XCTAssertNil(st.target)
        XCTAssertEqual(a.target?.element, 5)
        XCTAssertEqual(a.args["text"] as? String, "(hidden, 2 characters)")
    }

    /// Hidden text stays hidden in later reads of the window, which show its fields' values.
    func testHiddenTextIsTakenOutOfLaterReads() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "dear Ada", "element": 3])
        log.end(t, result: "Typed 8 characters.", isError: false)
        let r = log.begin(tool: "get_window_state", args: [:])
        log.end(r, result: "[3] TextArea value=\"dear Ada, hello\" @(0,0 10x10)", isError: false)
        XCTAssertFalse(r.result.contains("dear Ada"), r.result)
        // A key or two isn't taken out of everything after it.
        let k = log.begin(tool: "type_text", args: ["text": "\n"])
        log.end(k, result: "Typed 1 characters.", isError: false)
        let r2 = log.begin(tool: "get_window_state", args: [:])
        log.end(r2, result: "line one\nline two", isError: false)
        XCTAssertEqual(r2.result, "line one\nline two")
    }

    /// A status answered while a batch runs doesn't hide the batch's later steps' captions.
    func testStepsAreDrawnInTheOrderTheyStarted() {
        let (now, set) = clock()
        let log = StepLog(redactAll: false, clock: now)
        let b = log.begin(tool: "batch", args: [:])
        set(100); let b1 = log.begin(tool: "click", args: [:], inBatch: true); log.end(b1, result: "ok", isError: false)
        set(200); let st = log.begin(tool: "status", args: [:], tracked: false); log.end(st, result: "ok", isError: false)
        set(300); let b2 = log.begin(tool: "click", args: ["element": 9], inBatch: true); log.end(b2, result: "gone", isError: true)
        log.end(b, result: "", isError: true)
        let flat = StepLog.flatten(log.all)
        XCTAssertEqual(flat.map(\.t), [0, 100, 200, 300])
        XCTAssertTrue(RecordingOverlay.captionStep(flat, at: 10_000) === b2)
        XCTAssertTrue(RecordingOverlay.captionStep(flat, at: 400) === b, "each caption is held a moment, so none is skipped")
    }

    /// Steps closer together than a caption's hold, or between two frames,
    /// each get their caption, one after another.
    func testFastStepsEachGetACaption() {
        let (now, set) = clock()
        let log = StepLog(redactAll: false, clock: now)
        let a = log.begin(tool: "click", args: ["element": 9999]); set(5); log.end(a, result: "isn't there", isError: true)
        set(50); let b = log.begin(tool: "status", args: [:]); set(60); log.end(b, result: "ok", isError: false)
        let flat = StepLog.flatten(log.all)
        XCTAssertEqual(RecordingOverlay.captionTimes(flat), [0, 800])
        XCTAssertTrue(RecordingOverlay.captionStep(flat, at: 400) === a, "the failed click isn't covered by the status right after it")
        XCTAssertTrue(RecordingOverlay.captionStep(flat, at: 900) === b)
        XCTAssertEqual(RecordingOverlay.renderTimes(flat), [0, 50, 800], "frames are drawn for each caption even with no capture then")
    }

    /// A batch that stopped on a step is one failed tool call, not two.
    func testAFailedBatchCountsOnce() throws {
        let log = StepLog(redactAll: false, clock: { 0 })
        let b = log.begin(tool: "batch", args: [:])
        let c = log.begin(tool: "click", args: ["element": 9], inBatch: true)
        log.end(c, result: "gone", isError: true)
        log.end(b, result: "1. click FAILED: gone", isError: true)
        let info = ActionList.Info(started: Date(), durationMs: 1000, source: "display", windowID: nil, fps: 12, frames: 12,
                                   size: CGSize(width: 1600, height: 1000), label: "Agent", redactAll: false, video: "recording.mp4")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: ActionList.json(log.all, info: info)) as? [String: Any])
        XCTAssertEqual(obj["failed"] as? Int, 1)
        XCTAssertEqual(obj["failed_actions"] as? Int, 1)
        XCTAssertTrue(ActionList.markdown(log.all, info: info).contains("1 tool call, 1 failed"))
    }

    /// With all typed text hidden, the field it went into is covered in the video.
    func testHiddenTypingCoversTheField() throws {
        let log = StepLog(redactAll: true, clock: { 0 })
        let s = log.begin(tool: "type_text", args: ["text": "dear Ada", "element": 3])
        log.setTarget(StepTarget(element: 3, role: "AXTextField", label: "Note", frame: CGRect(x: 100, y: 100, width: 200, height: 40), secure: false))
        log.end(s, result: "Typed 8 characters.", isError: false)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        RecordingOverlay.draw(in: ctx, size: CGSize(width: 800, height: 500), t: 60_000, flat: log.all, total: 1,
                              mapping: FrameMapping(scale: 1, offset: .zero), label: "Agent", redactAll: true)
        let image = try XCTUnwrap(ctx.makeImage())
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let i = 135 * image.bytesPerRow + 290 * 4  // inside the field, right of the label, long after the step
        XCTAssertGreaterThan(data[i + 1], 100, "covered")
    }

    /// Saved while a step still runs (the app quits): what it's typing isn't written out.
    func testAnUnfinishedStepsTextIsHidden() throws {
        let log = StepLog(redactAll: false, clock: { 0 })
        _ = log.begin(tool: "type_text", args: ["text": "hunter2", "element": 5])
        let info = ActionList.Info(started: Date(), durationMs: 1000, source: "display", windowID: nil, fps: 12, frames: 12,
                                   size: CGSize(width: 1600, height: 1000), label: "Agent", redactAll: false, video: "recording.mp4")
        for text in [ActionList.markdown(log.all, info: info), String(decoding: ActionList.json(log.all, info: info), as: UTF8.self)] {
            XCTAssertFalse(text.contains("hunter2"), text)
        }
    }

    /// Typing turned away before anyone looked where it goes (paused, or the
    /// user has the display) is hidden: it may have been a password.
    func testRefusedTypingIsHidden() {
        let log = StepLog(redactAll: false, clock: { 0 })
        let t = log.begin(tool: "set_value", args: ["element": 5, "value": "hunter2"])
        log.end(t, result: "Paused by the user from the menu bar.", isError: true)
        XCTAssertEqual(t.args["value"] as? String, "(hidden, 7 characters)")
    }

    /// stop_recording that couldn't save the video is listed as failed.
    func testAFailedStopIsListedAsFailed() {
        let log = StepLog(redactAll: false, clock: { 0 })
        let s = log.begin(tool: "stop_recording", args: [:])
        log.end(s, result: "Stopped the recording and saved it.", isError: false)
        log.amend(s, result: "no frames were recorded, so there's no video.", isError: true)
        log.end(s, result: "ignored", isError: false)
        XCTAssertTrue(s.isError)
        XCTAssertTrue(s.result.hasPrefix("no frames"))
    }

    /// A PIN pressed key by key into a password field is hidden, keycaps and all.
    func testCharacterKeysIntoAPasswordFieldAreHidden() {
        let log = StepLog(redactAll: false, clock: { 0 })
        let k = log.begin(tool: "press_key", args: ["key": "7"])
        log.setFocus(secure: true)
        log.end(k, result: "Pressed 7.", isError: false)
        XCTAssertEqual(k.args["key"] as? String, "(hidden, 1 characters)")
        XCTAssertFalse(k.result.contains("7"), k.result)
        XCTAssertEqual(RecordingText.caption(tool: k.tool, args: k.args, target: nil, hidden: k.hidesText(redactAll: false)), "press_key (a hidden key)")
        XCTAssertTrue(RecordingOverlay.marking([k], at: 100).allSatisfy { $0.hidesText(redactAll: false) })
        // Shortcuts and keys into ordinary fields are shown.
        let c = log.begin(tool: "press_key", args: ["key": "l", "modifiers": ["cmd"]]); log.end(c, result: "Pressed cmd+l.", isError: false)
        XCTAssertEqual(c.args["key"] as? String, "l")
        let o = log.begin(tool: "press_key", args: ["key": "a"]); log.setFocus(secure: false); log.end(o, result: "Pressed a.", isError: false)
        XCTAssertEqual(o.args["key"] as? String, "a")
        XCTAssertEqual(RecordingText.caption(tool: "scroll", args: ["dy": Int.min], target: nil, hidden: false), "scroll up 9223372036854775808")
    }

    func testATargetNamedAfterHiddenTextIsRedacted() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "budget-2027.xlsx", "element": 2])
        log.end(t, result: "Typed 16 characters.", isError: false)
        let c = log.begin(tool: "click", args: ["element": 9])
        log.setTarget(StepTarget(element: 9, role: "AXRow", label: "budget-2027.xlsx", frame: .zero, secure: false))
        log.end(c, result: "Pressed.", isError: false)
        XCTAssertEqual(c.target?.label, "(hidden)")
    }

    func testHiddenTextIsTakenOutOfLaterArguments() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "budget-2027.xlsx"])
        log.end(t, result: "Typed 16 characters.", isError: false)
        let c = log.begin(tool: "choose_file", args: ["path": "/Users/x/budget-2027.xlsx", "list": ["a", "budget-2027.xlsx"]])
        log.end(c, result: "Chose it.", isError: false)
        XCTAssertEqual(c.args["path"] as? String, "/Users/x/(hidden)")
        XCTAssertEqual(c.args["list"] as? [String], ["a", "(hidden)"])
    }

    /// A read clips long values: the clipped form is taken out too.
    func testALongHiddenValueIsTakenOutOfAClippedRead() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let secret = String(repeating: "confidential-", count: 20)
        let t = log.begin(tool: "type_text", args: ["text": secret, "element": 3])
        log.end(t, result: "Typed.", isError: false)
        let r = log.begin(tool: "get_window_state", args: [:])
        log.end(r, result: "[3] TextArea value=\"\(secret.prefix(159))…\" @(0,0 10x10)", isError: false)
        XCTAssertFalse(r.result.contains("confidential-confidential"), r.result)
    }

    /// Typing that stopped partway left part of the text in the field: a later read doesn't show it.
    func testPartlyTypedHiddenTextIsTakenOutOfLaterReads() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "confidential-notes", "element": 3])
        log.end(t, result: "stopped typing: Typed 6 of 18 characters (\"confid\"), nothing after that.", isError: true)
        let r = log.begin(tool: "get_window_state", args: [:])
        log.end(r, result: "[3] TextField value=\"confid\" @(0,0 10x10)", isError: false)
        XCTAssertFalse(r.result.contains("confid"), r.result)
    }

    /// What was typed can run over several lines in an error.
    func testAMultilineFragmentIsHidden() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "alpha\nbravo\ncharlie", "element": 3])
        log.end(t, result: "stopped typing: Typed 9 of 19 characters (\"alpha\nbra\"), nothing after that.", isError: true)
        XCTAssertFalse(t.result.contains("alpha") || t.result.contains("bra\""), t.result)
        let b = log.begin(tool: "batch", args: [:])
        let c = log.begin(tool: "type_text", args: ["text": "alpha\nbravo", "element": 3], inBatch: true)
        log.end(c, result: "x", isError: true)
        log.end(b, result: "1. type_text FAILED: Typed 8 of 11 characters (\"alpha\nbr\"), nothing after that.\nStopped.", isError: true)
        XCTAssertFalse(b.result.contains("alpha") || b.result.contains("br\""), b.result)
        XCTAssertTrue(b.result.hasSuffix("\nStopped."))
    }

    /// A step's text is hidden and tracked as given, not as redacted against earlier steps.
    func testPartlyTypedTextUsesWhatWasAskedFor() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let a = log.begin(tool: "type_text", args: ["text": "Ada", "element": 3]); log.end(a, result: "ok", isError: false)
        let b = log.begin(tool: "type_text", args: ["text": "Ada Lovelace", "element": 3])
        log.end(b, result: "Typed 7 of 12 characters (\"Ada Lov\")", isError: true)
        XCTAssertEqual(b.args["text"] as? String, "(hidden, 12 characters)")
        let r = log.begin(tool: "get_window_state", args: [:])
        log.end(r, result: "value=\"Ada Lov\"", isError: false)
        XCTAssertFalse(r.result.contains("Lov"), r.result)
    }

    func testShiftSpellingsCountAsTyping() {
        XCTAssertTrue(RecordedStep.typesACharacter(["key": "A", "modifiers": ["⇧"]]))
        XCTAssertTrue(RecordedStep.typesACharacter(["key": "A", "modifiers": [" Shift "]]))
        XCTAssertFalse(RecordedStep.typesACharacter(["key": "a", "modifiers": ["cmd"]]))
    }

    func testARefusedLongInputIsQuick() {
        XCTAssertEqual(RecordingText.partsTyped(String(repeating: "x", count: 8000), result: "Paused by the user. Nothing was typed."), [])
        let parts = RecordingText.partsTyped(String(repeating: "x", count: 8000), result: "it failed")
        XCTAssertLessThanOrEqual(parts.count, RecordingText.maxPartsTyped)
    }

    func testTypingFailuresAreLoggedWithoutWhatWasTyped() {
        XCTAssertEqual(Engine.loggable("type_text FAILED: Typed 4 of 7 characters (\"hunt\"), nothing after that."),
                       "type_text FAILED: Typed 4 of 7 characters (\"(hidden)\"), nothing after that.")
        XCTAssertEqual(Engine.loggable("click FAILED: no \"Save\" button"), "click FAILED: no \"Save\" button")
    }

    func testASubagentsStopFollowsOnlyItsOwnRecording() {
        XCTAssertTrue(Hub.routeHolds(dir: "/r/a", current: "/r/a"))
        XCTAssertFalse(Hub.routeHolds(dir: "/r/a", current: "/r/b"), "the owner stopped it and started another")
        XCTAssertFalse(Hub.routeHolds(dir: "/r/a", current: nil))
    }

    func testHugeNumbersInArgumentsDontCrashCaptions() {
        XCTAssertEqual(RecordingText.caption(tool: "click", args: ["x": 1e300, "y": 5], target: nil, hidden: false), "click at (1e+300, 5)")
        XCTAssertEqual(RecordingText.caption(tool: "wait", args: ["ms": Double.infinity], target: nil, hidden: false), "wait inf ms")
        XCTAssertFalse(RecordingText.caption(tool: "drag", args: ["from_x": -1e40, "from_y": 0, "to_x": 1, "to_y": 2], target: nil, hidden: false).isEmpty)
    }

    func testPruningSparesRecordingsUnderWay() {
        let dirs = (1...25).reversed().map { URL(fileURLWithPath: "/r/\(String(format: "%02d", $0))", isDirectory: true) }
        let gone = AgentRecording.prunable(dirs, keep: 20, protected: ["/r/02"])
        XCTAssertEqual(gone.map(\.lastPathComponent), ["05", "04", "03", "01"])
    }

    func testHideTypingHidesAllTypedText() {
        let log = StepLog(redactAll: true, clock: { 0 })
        let t = log.begin(tool: "type_text", args: ["text": "dear Ada"])
        log.end(t, result: "Typed 8 characters.", isError: false)
        XCTAssertEqual(t.args["text"] as? String, "(hidden, 8 characters)")
    }

    func testActionListMatchesToolCallsOneToOne() throws {
        let (now, set) = clock()
        let log = StepLog(redactAll: false, clock: now)
        let calls: [(String, Bool)] = [("start_recording", false), ("open_window", false), ("get_window_state", false),
                                       ("click", false), ("click", true), ("status", false), ("stop_recording", false)]
        for (i, (tool, fails)) in calls.enumerated() {
            set(Double(i) * 1000)
            let s = log.begin(tool: tool, args: ["window_id": 1])
            set(Double(i) * 1000 + 300)
            log.end(s, result: fails ? "element 99 isn't in the last get_window_state for window 1" : "ok", isError: fails)
        }
        let info = ActionList.Info(started: Date(), durationMs: 7000, source: "display", windowID: nil, fps: 12, frames: 84,
                                   size: CGSize(width: 1600, height: 1000), label: "Agent", redactAll: false, video: "recording.mp4")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: ActionList.json(log.all, info: info)) as? [String: Any])
        let actions = try XCTUnwrap(obj["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.map { $0["tool"] as? String }, calls.map(\.0))
        XCTAssertEqual(actions.map { $0["error"] as? Bool }, calls.map(\.1))
        XCTAssertEqual(obj["failed"] as? Int, 1)
        XCTAssertEqual(actions[4]["time"] as? String, "00:04.0")
        let md = ActionList.markdown(log.all, info: info)
        XCTAssertTrue(md.contains("7 tool calls, 1 failed"))
        XCTAssertTrue(md.contains("5. `00:04.0` ❌ **click at (0, 0)**"), md)
        XCTAssertTrue(md.contains("<details><summary>What it read"), "reads are listed, collapsed")
    }

    // MARK: Marks and timing

    func testCaptionAndMarksFollowTheSteps() {
        let (now, set) = clock()
        let log = StepLog(redactAll: false, clock: now)
        let a = log.begin(tool: "click", args: ["element": 1]); set(100); log.end(a, result: "Pressed", isError: false)
        set(5000)
        let b = log.begin(tool: "press_key", args: ["key": "l", "modifiers": ["cmd"]]); set(5100); log.end(b, result: "Pressed", isError: false)
        let flat = StepLog.flatten(log.all)
        XCTAssertNil(RecordingOverlay.captionStep(flat, at: -1))
        XCTAssertEqual(RecordingOverlay.captionStep(flat, at: 4000)?.tool, "click", "a caption stays until the next step")
        XCTAssertEqual(RecordingOverlay.captionStep(flat, at: 5000)?.tool, "press_key")
        XCTAssertEqual(RecordingOverlay.marking(flat, at: 1000).map(\.tool), ["click"])
        XCTAssertEqual(RecordingOverlay.marking(flat, at: 3000).map(\.tool), [], "marks fade after a moment")
    }

    func testOverlayDrawsWithoutCrashingAndMarksTheTarget() throws {
        let log = StepLog(redactAll: false, clock: { 0 })
        let s = log.begin(tool: "click", args: ["element": 26])
        log.setTarget(StepTarget(element: 26, role: "AXButton", label: "Reload this page", frame: CGRect(x: 100, y: 100, width: 40, height: 30), secure: false))
        log.setPoint(CGPoint(x: 120, y: 115), click: true)
        log.end(s, result: "element 26 no longer exists", isError: true)
        let size = CGSize(width: 800, height: 500)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        RecordingOverlay.draw(in: ctx, size: size, t: 300, flat: log.all, total: 1, mapping: FrameMapping(scale: 0.5, offset: .zero),
                              label: "Agent", redactAll: false)
        let image = try XCTUnwrap(ctx.makeImage())
        // The box's edge, at (50, 50)-(70, 65) in the frame after the 0.5 scale: red for a failure.
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let row = image.bytesPerRow
        func pixel(_ x: Int, _ yTop: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = yTop * row + x * 4  // BGRA in memory, top row first
            return (data[i + 2], data[i + 1], data[i])
        }
        let edge = pixel(48, 58)
        XCTAssertGreaterThan(edge.r, 180, "\(edge)")
        XCTAssertLessThan(edge.b, 120, "\(edge)")
        // The caption bar along the bottom is red too.
        let bar = pixel(400, 495)
        XCTAssertGreaterThan(bar.r, 120, "\(bar)")
    }

    func testVideoSizeAndFit() {
        XCTAssertEqual(AgentRecording.videoSize(CGSize(width: 1600, height: 1000)), CGSize(width: 1600, height: 1000))
        XCTAssertEqual(AgentRecording.videoSize(CGSize(width: 801, height: 603)), CGSize(width: 800, height: 602))
        XCTAssertEqual(AgentRecording.videoSize(CGSize(width: 3840, height: 2160)).width, 1920)
        XCTAssertEqual(AgentRecording.fit(CGSize(width: 400, height: 200), in: CGSize(width: 800, height: 800)), CGRect(x: 0, y: 200, width: 800, height: 400))
    }

    // MARK: Engine wiring

    /// Every call is listed, refused and failed ones included, and a batch's
    /// steps under it, with no display needed.
    func testEngineListsEveryCall() {
        let engine = Engine(sessionID: "recording-list-test", label: "Agent", focusGuard: FocusGuard())
        let log = StepLog(redactAll: false, clock: { 0 })
        engine.testStepLog = log
        _ = engine.call(tool: "status", args: [:])
        _ = engine.call(tool: "click", args: ["window_id": 987_654_321, "element": 4])
        _ = engine.call(tool: "batch", args: ["window_id": 987_654_321, "actions": [["tool": "wait", "ms": 5], ["tool": "click", "element": 1]]])
        _ = engine.call(tool: "list_windows", args: [:])
        let steps = log.all
        XCTAssertEqual(steps.map(\.tool), ["status", "click", "batch", "list_windows"])
        XCTAssertEqual(steps.map(\.isError), [false, true, true, false])
        XCTAssertEqual(steps[2].steps.map(\.tool), ["wait", "click"])
        XCTAssertEqual(steps[2].steps.map(\.isError), [false, true])
        XCTAssertTrue(steps.allSatisfy { $0.end != nil })
    }

    func testStopWithoutARecordingSaysSo() {
        let engine = Engine(sessionID: "recording-stop-test", label: "Agent", focusGuard: FocusGuard())
        let r = engine.call(tool: "stop_recording", args: [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("no recording is under way"), r.text)
    }

    func testStopRecordingIsNeverRefused() {
        XCTAssertNil(Engine.refusal(tool: "stop_recording", userInControl: true, paused: true, notes: { nil }))
        XCTAssertNotNil(Engine.refusal(tool: "start_recording", userInControl: false, paused: true, notes: { nil }))
    }

    func testToolsAreListed() {
        let names = ToolCatalog.tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("start_recording"))
        XCTAssertTrue(names.contains("stop_recording"))
    }

    // MARK: The pointer of a press (#114's separate bug)

    /// An element's frame from the last read goes stale when its display
    /// moves (another agent display before it went away): the press is
    /// shown where the element is now.
    func testAPressIsShownWhereTheElementIsNow() {
        let read = CGRect(x: 3280 + 555, y: 2050 + 12, width: 23, height: 29)
        let now = read.offsetBy(dx: -1600, dy: -1000)
        XCTAssertEqual(Engine.currentFrame(live: now, read: read), now)
        XCTAssertEqual(Engine.currentFrame(live: nil, read: read), read)
        XCTAssertEqual(Engine.currentFrame(live: .zero, read: read), read)
    }

    func testHistoryPointerUsesTheDisplayWhereThePointWasWorkedOut() {
        let p = AgentPointer(point: CGPoint(x: 1680 + 590, y: 1050 + 81), kind: .click)
        let rel = SessionRecorder.relative(p, display: CGRect(x: 1680, y: 1050, width: 1600, height: 1000))
        XCTAssertEqual(rel.point, CGPoint(x: 590, y: 81))
        XCTAssertTrue(rel.click)
    }
}
