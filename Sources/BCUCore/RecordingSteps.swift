import Foundation
import CoreGraphics
import BCUShared

/// What a recorded step acted on: an element of the agent's window, as the
/// last `get_window_state` numbered it, where it was when the step ran.
public struct StepTarget: Equatable {
    public let element: Int
    /// Without "AX": "Button", "TextField".
    public let role: String
    public let label: String
    /// Display-relative points, top-left origin.
    public let frame: CGRect
    public let secure: Bool

    public init(element: Int, role: String, label: String, frame: CGRect, secure: Bool) {
        self.element = element
        self.role = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        self.label = label
        self.frame = frame
        self.secure = secure
    }

    /// `"Reload this page" (Button)`, or `element 26 (Button)` when it has no name.
    public var name: String {
        label.isEmpty ? "element \(element) (\(role))" : "\"\(RecordingText.clip(label, 60))\" (\(role))"
    }
}

/// One tool call made while recording (or one step of a batch).
public final class RecordedStep {
    /// The tool call's number in the recording, from 1.
    public let n: Int
    /// Its step number within a batch, from 1; nil for a tool call.
    public let sub: Int?
    public let tool: String
    /// The call's arguments, with typed text taken out once it's known to be secret.
    public internal(set) var args: JSONObject
    /// Milliseconds from the start of the video.
    public let t: Double
    public internal(set) var end: Double?
    public internal(set) var target: StepTarget?
    /// Where it landed, display-relative points.
    public internal(set) var point: CGPoint?
    public internal(set) var dragTo: CGPoint?
    public internal(set) var clicked = false
    public internal(set) var result = ""
    public internal(set) var isError = false
    public internal(set) var waits: [String] = []
    public internal(set) var steps: [RecordedStep] = []
    /// The focused field was a password field when text was typed without `element`.
    var focusSecure = false
    /// What it typed that's hidden, to take out of its batch's result too. Never written anywhere.
    var secret: String?

    init(n: Int, sub: Int?, tool: String, args: JSONObject, t: Double) {
        self.n = n
        self.sub = sub
        self.tool = tool
        self.args = args
        self.t = t
    }

    /// "4" or "4.2".
    public var number: String { sub.map { "\(n).\($0)" } ?? "\(n)" }
    public var durationMs: Double { max(0, (end ?? t) - t) }

    /// Whether what it typed or set is hidden: a password field, or the
    /// recording hides all typed text.
    func hidesText(redactAll: Bool) -> Bool {
        guard tool == "type_text" || tool == "set_value" else { return false }
        return redactAll || target?.secure == true || focusSecure
    }
}

/// Short texts for captions and the action list.
public enum RecordingText {
    public static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }

    static let keySymbols: [String: String] = [
        "cmd": "⌘", "command": "⌘", "shift": "⇧", "option": "⌥", "alt": "⌥", "ctrl": "⌃", "control": "⌃", "fn": "fn",
        "return": "⏎", "enter": "⏎", "tab": "⇥", "space": "Space", "escape": "esc", "delete": "⌫", "forward_delete": "⌦",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "Home", "end": "End", "page_up": "PgUp", "page_down": "PgDn",
    ]

    /// The keycaps a press_key shows: modifiers in macOS order, then the key.
    public static func keycaps(key: String, modifiers: [String]) -> [String] {
        let order = ["ctrl", "control", "option", "alt", "shift", "cmd", "command", "fn"]
        let mods = modifiers.map { $0.lowercased() }.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        var caps = mods.map { keySymbols[$0] ?? $0 }
        let k = key.lowercased()
        caps.append(keySymbols[k] ?? (key.count == 1 ? key.uppercased() : key.uppercased()))
        return caps
    }

    /// What a step did, in a line: `click "Save" (Button)`,
    /// `type_text "hello" into "Email" (TextField)`, `press_key ⌘L`.
    /// `hidden`: what it typed or set isn't shown.
    public static func caption(tool: String, args: JSONObject, target: StepTarget?, hidden: Bool) -> String {
        let a = Args(args)
        let on = target.map { " " + $0.name } ?? (a.int("element").map { " element \($0)" } ?? "")
        // Once a step ends, what it typed is already "(hidden, N characters)" in its arguments.
        let typed: (String) -> String = { v in
            guard hidden else { return "\"\(clip(v, 48))\"" }
            return v.hasPrefix("(hidden") ? v : "(hidden, \(v.count) characters)"
        }
        switch tool {
        case "click":
            var verb = "click"
            if a.string("button")?.lowercased() == "right" { verb = "right-click" }
            if (a.int("count") ?? 1) >= 2 { verb = "double-click" }
            if target != nil || a.int("element") != nil { return verb + on }
            return "\(verb) at (\(Int(a.double("x") ?? 0)), \(Int(a.double("y") ?? 0)))"
        case "type_text":
            let text = a.string("text") ?? ""
            return "type_text \(typed(text))" + (target.map { " into " + $0.name } ?? "")
        case "set_value":
            return "set_value" + on + " = " + typed(a.string("value") ?? "")
        case "press_key":
            return "press_key " + keycaps(key: a.string("key") ?? "?", modifiers: a.strings("modifiers") ?? []).joined()
        case "navigate":
            var url = a.string("url") ?? ""
            for p in ["https://", "http://"] where url.hasPrefix(p) { url = String(url.dropFirst(p.count)) }
            return "navigate " + clip(url, 70)
        case "scroll":
            let dy = a.int("dy") ?? 0, dx = a.int("dx") ?? 0
            var dir: [String] = []
            if dy != 0 { dir.append(dy > 0 ? "down \(dy)" : "up \(-dy)") }
            if dx != 0 { dir.append(dx > 0 ? "right \(dx)" : "left \(-dx)") }
            return "scroll " + (dir.isEmpty ? "0" : dir.joined(separator: ", ")) + (on.isEmpty ? "" : " in" + on)
        case "perform_action":
            return "perform_action \(a.string("action") ?? "?") on" + (on.isEmpty ? " ?" : on)
        case "press_menu_item":
            return "press_menu_item " + (a.strings("path") ?? []).joined(separator: " > ")
        case "drag":
            return "drag (\(Int(a.double("from_x") ?? 0)), \(Int(a.double("from_y") ?? 0))) → (\(Int(a.double("to_x") ?? 0)), \(Int(a.double("to_y") ?? 0)))"
        case "open_window", "borrow_window":
            return "\(tool) \(a.string("app") ?? "")".trimmingCharacters(in: .whitespaces)
        case "choose_file":
            return "choose_file " + clip(a.string("path") ?? "", 60)
        case "handoff":
            return "handoff: " + clip(a.string("reason") ?? "", 70)
        case "wait":
            return "wait \(Int(a.double("ms") ?? 500)) ms"
        case "batch":
            let n = (args["actions"] as? Int) ?? (args["actions"] as? [Any])?.count ?? 0
            return "batch of \(n) action\(n == 1 ? "" : "s")"
        case "get_window_state":
            return "get_window_state (read the window)"
        case "start_recording":
            return a.int("window_id").map { "start_recording of window \($0)" } ?? "start_recording"
        default:
            if let w = a.int("window_id"), tool == "release_window" || tool == "screenshot" { return "\(tool) \(w)" }
            return tool
        }
    }

    /// The result's first line, or for a failure the line that says what failed.
    public static func outcome(_ result: String, isError: Bool) -> String {
        let lines = result.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if isError, let failed = lines.first(where: { $0.contains(" FAILED: ") || $0.hasPrefix("Stopped") }) { return failed }
        return lines.first ?? ""
    }

    /// The waits a result reports ("[user first] …", "[other agents] …").
    public static func waits(in result: String) -> [String] {
        result.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[user first]") || $0.hasPrefix("[other agents]") }
    }

    /// `text` with everything in double quotes replaced: for the result of a
    /// step whose text is hidden, which can quote part of it ("Typed 4 of 7
    /// characters ("hunt")").
    public static func hideQuoted(_ text: String) -> String {
        var out = "", inQuote = false
        for ch in text {
            if ch == "\"" {
                out.append(ch)
                if !inQuote { out += "(hidden)" }
                inQuote.toggle()
            } else if !inQuote {
                out.append(ch)
            }
        }
        return out
    }

    /// Whether hidden text is also taken out of later results: not a key or
    /// two ("\n", "a"), which would blank half of every read.
    static func redactsLater(_ secret: String) -> Bool {
        secret.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    /// `text` with every occurrence of each secret (of at least 1 character) taken out.
    public static func redact(_ text: String, secrets: [String]) -> String {
        var out = text
        for s in secrets where !s.isEmpty { out = out.replacingOccurrences(of: s, with: "(hidden)") }
        return out
    }

    /// m:ss.s
    public static func clock(_ ms: Double) -> String {
        let s = max(0, ms) / 1000
        return String(format: "%02d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// The recording's list of steps, safe to use from any thread: the session's
/// queue adds them, and `status` (answered off that queue) can too.
public final class StepLog {
    private let lock = NSLock()
    private var steps: [RecordedStep] = []
    /// Steps begun and not yet ended, innermost last.
    private var open: [RecordedStep] = []
    /// Text that was hidden where it was typed, taken out of every later
    /// result too (a read of the window shows what's in its fields). Never
    /// written anywhere.
    private var hiddenTexts: [String] = []
    public let redactAll: Bool
    private let clock: () -> Double

    /// `clock`: milliseconds since the video started.
    public init(redactAll: Bool, clock: @escaping () -> Double) {
        self.redactAll = redactAll
        self.clock = clock
    }

    public var all: [RecordedStep] { lock.lock(); defer { lock.unlock() }; return steps }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return steps.count }

    /// A tool call starts (or, inside a batch that's being recorded, one of its steps).
    /// `tracked`: what the session finds out while it runs (its target, where
    /// it lands) goes to it. A call answered off the session's queue
    /// (`status`, from another thread) isn't, so it never takes what belongs
    /// to the action running at the same time.
    @discardableResult
    public func begin(tool: String, args: JSONObject, inBatch: Bool = false, tracked: Bool = true) -> RecordedStep {
        lock.lock(); defer { lock.unlock() }
        var a = args
        a["_session"] = nil
        if inBatch, let parent = open.last(where: { $0.sub == nil && $0.tool == "batch" }) {
            let s = RecordedStep(n: parent.n, sub: parent.steps.count + 1, tool: tool, args: a, t: clock())
            parent.steps.append(s)
            open.append(s)
            return s
        }
        // A batch's steps are listed one by one, each with what it typed
        // hidden where it has to be: its arguments keep only how many.
        if tool == "batch" { a["actions"] = (a["actions"] as? [Any])?.count ?? 0 }
        let s = RecordedStep(n: steps.count + 1, sub: nil, tool: tool, args: a, t: clock())
        steps.append(s)
        if tracked { open.append(s) }
        return s
    }

    /// The step under way (the innermost one).
    private var current: RecordedStep? { open.last }

    public func setTarget(_ target: StepTarget) {
        lock.lock(); defer { lock.unlock() }
        current?.target = target
    }

    public func setPoint(_ p: CGPoint, click: Bool, dragTo: CGPoint? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let s = current else { return }
        // A click's point wins over a move that comes after it.
        if s.clicked && !click { return }
        s.point = p
        s.clicked = s.clicked || click
        if let dragTo { s.dragTo = dragTo }
    }

    public func setFocusSecure() {
        lock.lock(); defer { lock.unlock() }
        current?.focusSecure = true
    }

    /// The step ended with `result`. Typed text that's to be hidden goes
    /// from its arguments and result now, before anything is written.
    public func end(_ s: RecordedStep, result: String, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard s.end == nil else { return }
        s.end = clock()
        s.isError = isError
        // Text hidden in an earlier step, wherever it shows up again.
        var result = RecordingText.redact(result, secrets: hiddenTexts)
        if s.hidesText(redactAll: redactAll) {
            let key = s.tool == "type_text" ? "text" : "value"
            if let secret = s.args[key] as? String {
                result = RecordingText.hideQuoted(RecordingText.redact(result, secrets: [secret]))
                s.args[key] = "(hidden, \(secret.count) characters)"
                s.secret = secret
                if RecordingText.redactsLater(secret) { hiddenTexts.append(secret) }
            }
        }
        if s.tool == "batch" {
            result = RecordingText.redact(result, secrets: s.steps.compactMap(\.secret))
            // A step's line may quote part of what it typed (typing that
            // stopped partway says what went in): hide the quotes in the
            // lines of steps whose text is hidden.
            let hiddenSteps = Set(s.steps.filter { $0.secret != nil }.compactMap(\.sub))
            result = result.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let l = String(line)
                guard let dot = l.firstIndex(of: "."), let k = Int(l[..<dot]), hiddenSteps.contains(k) else { return l }
                return RecordingText.hideQuoted(l)
            }.joined(separator: "\n")
            for c in s.steps { c.secret = nil }
        }
        if s.sub == nil { s.secret = nil }
        s.result = result
        s.waits = RecordingText.waits(in: result)
        open.removeAll { $0 === s }
    }

    /// Every step, batch steps after their batch, in the order they started.
    /// In the order they started: a call answered off the session's queue
    /// (status) can start while a batch's steps are running.
    public static func flatten(_ steps: [RecordedStep]) -> [RecordedStep] {
        steps.flatMap { [$0] + $0.steps }.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
    }
}
