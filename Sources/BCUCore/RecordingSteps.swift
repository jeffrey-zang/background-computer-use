import Foundation
import CoreGraphics
import ApplicationServices
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
    /// Display points its typing may have reached beyond its target (a Tab
    /// moves on to other fields): the video covers it too when typing is hidden.
    public internal(set) var cover: CGRect?
    /// The window that `cover` is, followed from frame to frame.
    public internal(set) var coverWindow: CGWindowID?
    /// The focused field was a password field when text was typed without `element`.
    var focusSecure = false
    /// Its text (or key) was taken out of its arguments when it ended.
    var textHidden = false
    /// What it was asked to type, as given (later arguments are redacted
    /// when it starts, but what's hidden and what went in come from this).
    /// Never written anywhere.
    var original: [String: String] = [:]
    /// A press_key of one character (no modifier but shift), from its
    /// arguments as given (the stored ones can be redacted).
    var typesCharacter = false
    /// The field it acted on, to follow in the video (a page can scroll).
    var field: AXUIElement?
    /// Its text holds a Tab: it can reach more than one field.
    public internal(set) var multiField = false
    /// Run by another session and typed something there: its result is left out.
    var foreignTyping = false
    /// Its window_id, for keeping key runs per window.
    var window: UInt32?
    var originalModifiers: [String] = []
    /// Where its typing goes was looked at (an element, or the focus).
    var focusChecked = false
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
    /// A step still running (the recording is saved as the app quits) may
    /// not know yet where its text goes, so it's hidden too.
    func hidesText(redactAll: Bool) -> Bool {
        if textHidden { return true }
        // A character key on its own is typing one key at a time (a PIN).
        if tool == "press_key" {
            guard typesCharacter else { return false }
            return redactAll || focusSecure || target?.secure == true || end == nil || !focusChecked
        }
        guard tool == "type_text" || tool == "set_value" else { return false }
        // Not knowing where it went (refused before it got that far) counts as secret.
        return redactAll || target?.secure == true || focusSecure || end == nil || (target == nil && !focusChecked)
    }

    /// A press_key of one printable character, with no modifier but shift.
    /// Typed text that can go on in another field: a Tab, or a Return with
    /// more typed after it (an app can move focus on Return, e.g. to a
    /// password field).
    static func reachesAnotherField(_ text: String) -> Bool {
        if text.contains("\t") { return true }
        guard let r = text.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) else { return false }
        return !text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func typesACharacter(_ args: JSONObject) -> Bool {
        guard let key = args["key"] as? String, key.count == 1, let ch = key.first, !ch.isWhitespace else { return false }
        // Every spelling press_key takes for shift ("⇧", " Shift ").
        let mods = (args["modifiers"] as? [Any] ?? []).map { "\($0)".trimmingCharacters(in: .whitespaces).lowercased() }
        // Shift and option change which character goes in (option+s is ß);
        // cmd, ctrl and fn make it a shortcut.
        return mods.allSatisfy { [.maskShift, .maskAlternate].contains(KeyMap.modifierNames[$0]) }
    }

    /// Its arguments as written out: typed text that's to be hidden and
    /// isn't yet (the step hasn't ended) is left out.
    func exportedArgs(redactAll: Bool) -> JSONObject {
        var a = args
        // Not hidden yet (still running): whatever it holds, even text that
        // looks like a placeholder, goes.
        if hidesText(redactAll: redactAll) && !textHidden {
            for key in ["text", "value", "key"] {
                if let v = a[key] as? String { a[key] = "(hidden, \(v.count) characters)" }
            }
        }
        return a
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
            return isPlaceholder(v) ? v : "(hidden, \(v.count) characters)"
        }
        switch tool {
        case "click":
            var verb = "click"
            if a.string("button")?.lowercased() == "right" { verb = "right-click" }
            if (a.int("count") ?? 1) >= 2 { verb = "double-click" }
            if target != nil || a.int("element") != nil { return verb + on }
            return "\(verb) at (\(num(a.double("x"))), \(num(a.double("y"))))"
        case "type_text":
            let text = a.string("text") ?? ""
            return "type_text \(typed(text))" + (target.map { " into " + $0.name } ?? "")
        case "set_value":
            return "set_value" + on + " = " + typed(a.string("value") ?? "")
        case "press_key":
            if hidden { return "press_key (a hidden key)" }
            return "press_key " + keycaps(key: a.string("key") ?? "?", modifiers: a.strings("modifiers") ?? []).joined()
        case "navigate":
            var url = a.string("url") ?? ""
            for p in ["https://", "http://"] where url.hasPrefix(p) { url = String(url.dropFirst(p.count)) }
            return "navigate " + clip(url, 70)
        case "scroll":
            let dy = a.int("dy") ?? 0, dx = a.int("dx") ?? 0
            var dir: [String] = []
            // `magnitude`: -Int.min overflows.
            if dy != 0 { dir.append(dy > 0 ? "down \(dy)" : "up \(dy.magnitude)") }
            if dx != 0 { dir.append(dx > 0 ? "right \(dx)" : "left \(dx.magnitude)") }
            return "scroll " + (dir.isEmpty ? "0" : dir.joined(separator: ", ")) + (on.isEmpty ? "" : " in" + on)
        case "perform_action":
            return "perform_action \(a.string("action") ?? "?") on" + (on.isEmpty ? " ?" : on)
        case "press_menu_item":
            return "press_menu_item " + (a.strings("path") ?? []).joined(separator: " > ")
        case "drag":
            return "drag (\(num(a.double("from_x"))), \(num(a.double("from_y")))) → (\(num(a.double("to_x"))), \(num(a.double("to_y"))))"
        case "open_window", "borrow_window":
            return "\(tool) \(a.string("app") ?? "")".trimmingCharacters(in: .whitespaces)
        case "choose_file":
            return "choose_file " + clip(a.string("path") ?? "", 60)
        case "handoff":
            return "handoff: " + clip(a.string("reason") ?? "", 70)
        case "wait":
            return "wait \(num(a.double("ms") ?? 500)) ms"
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

    /// Every field value in a window read (`value="…"` up to where the line
    /// goes on with its frame or flags) replaced: under hide_typing, once
    /// something was typed, a field can hold an edited or partial copy of it.
    static func hideValues(_ text: String) -> String {
        let frame = #"@\(-?\d+,-?\d+ \d+x\d+\)"#
        // A text field's name first (it can be its contents), up to what
        // follows it on the line: its value, placeholder or frame.
        return text.replacingOccurrences(of: #"((?:SecureTextField|TextField|TextArea|SearchField|ComboBox)(?:\([^)\n]*\))?) "[^\n]*?"(?= value="| value=\(hidden\)| placeholder="| "# + frame + ")",
                                         with: "$1 \"(hidden)\"", options: [.regularExpression])
            // Then every value, up to the frame that ends the line (it can
            // hold quotes and brackets itself).
            .replacingOccurrences(of: #"value="[^\n]*"(?= "# + frame + #")|value="[^\n]*"$"#, with: "value=(hidden)",
                                  options: [.regularExpression])
    }

    /// Window titles in a read (`Window 7 "…" of App`, and the windows a
    /// status or list_windows lists, `7: App [opened] "…"`) replaced: an app
    /// can show what was typed in its title.
    static func hideTitles(_ text: String) -> String {
        text.replacingOccurrences(of: #"(Window \d+ )"[^\n]*"(?= of )"#, with: "$1\"(hidden)\"", options: .regularExpression)
            // `7: App [opened] "…"` (status) and `7: App "…" [opened]` (list_windows).
            .replacingOccurrences(of: #"(?m)^(\s*\d+: [^\n"]*) "[^\n]*"(?=( \[[^\]\n]*\])?$)"#, with: "$1 \"(hidden)\"", options: .regularExpression)
            // The user's other windows: `7: "…" 800x600 (the user's)`.
            .replacingOccurrences(of: #"(?m)^(\s*\d+: )"[^\n]*"(?= \d+x\d+)"#, with: "$1\"(hidden)\"", options: .regularExpression)
    }

    /// Every word (between spaces, quotes or line breaks) holding a
    /// character outside ASCII, replaced.
    static func hideNonASCIIWords(_ text: String) -> String {
        text.replacingOccurrences(of: #"[^\s"]*[^\x00-\x7F][^\s"]*"#, with: "(hidden)", options: .regularExpression)
    }

    /// The exact form a hidden value is replaced with.
    static func isPlaceholder(_ v: String) -> Bool {
        v.range(of: #"^\(hidden, \d+ characters\)$"#, options: .regularExpression) != nil
    }

    /// The text inside double quotes in `text`: each quoted span, and the
    /// whole stretch from the first quote to the last.
    static func quotedSpans(_ text: String) -> [String] {
        var out: [String] = []
        let parts = text.split(separator: "\"", omittingEmptySubsequences: false)
        if parts.count >= 3 { for i in stride(from: 1, to: parts.count - 1, by: 2) { out.append(String(parts[i])) } }
        if let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last {
            out.append(String(text[text.index(after: first)..<last]))
        }
        return out
    }

    /// `text` with everything in double quotes replaced: for the result of a
    /// step whose text is hidden, which can quote part of it ("Typed 4 of 7
    /// characters ("hunt")").
    public static func hideQuoted(_ text: String) -> String {
        // From the first quote to the last: what was typed can hold quotes
        // and line breaks itself, so neither says where it ends.
        guard let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last else { return text }
        return String(text[...first]) + "(hidden)" + String(text[last...])
    }

    /// What of `secret` may be in the field after typing it failed: the
    /// part the error says went in ("Typed 6 of 18 characters"), else every
    /// start of it.
    static func partsTyped(_ secret: String, result: String) -> [String] {
        if let r = result.range(of: #"Typed (\d+) of \d+"#, options: .regularExpression),
           let n = Int(result[r].split(separator: " ")[1]) {
            return [String(secret.prefix(n))]
        }
        // Turned away before typing anything: nothing went in.
        if result.localizedCaseInsensitiveContains("nothing was typed") || result.localizedCaseInsensitiveContains("nothing was done") { return [] }
        // Otherwise every start of it, up to a bound (a long document
        // refused for another reason mustn't take seconds and megabytes).
        return (3..<max(3, min(secret.count, maxPartsTyped))).map { String(secret.prefix($0)) }
    }
    static let maxPartsTyped = 64

    /// `hideQuoted` on each hidden batch step's part of a batch result: from
    /// its line ("2. type_text FAILED: …") to the next step's, since what
    /// it quotes can run over several lines.
    static func hideQuotedInSteps(_ result: String, _ steps: Set<Int>) -> String {
        guard !steps.isEmpty else { return result }
        var lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func stepNumber(_ l: String) -> Int? {
            guard let dot = l.firstIndex(of: "."), let k = Int(l[..<dot]) else { return nil }
            return k
        }
        var i = 0
        while i < lines.count {
            guard let k = stepNumber(lines[i]), steps.contains(k) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, stepNumber(lines[j]) == nil, !lines[j].hasPrefix("Stopped"), !lines[j].isEmpty { j += 1 }
            let part = hideQuoted(lines[i..<j].joined(separator: "\n")).split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                // A quote cut off (a batch keeps a result's first line): the rest of the line.
                let l = String(line)
                guard l.filter({ $0 == "\"" }).count % 2 == 1, let q = l.lastIndex(of: "\"") else { return l }
                return String(l[..<q]) + "\"(hidden)"
            }
            lines.replaceSubrange(i..<j, with: part)
            i += part.count
        }
        return lines.joined(separator: "\n")
    }

    /// The ways a window read can show `secret`: as typed, on one line, and
    /// cut short where a read clips a value (160 characters) or a name (100).
    static func forms(of secret: String) -> [String] {
        let oneLine = secret.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var out = [secret, oneLine]
        // A Tab or Return typed as a key moves on: each piece can land in a field of its own.
        let pieces = secret.components(separatedBy: CharacterSet(charactersIn: "\t\n\r")).map { $0.trimmingCharacters(in: .whitespaces) }
        if pieces.count > 1 { out += pieces.flatMap { forms(of: $0) } }
        // 160 for a value, 100 for a name in a read, 80 for a target's label.
        // A read keeps that many characters, then "…".
        for n in [160, 100, 80] where oneLine.count > n { out.append(String(oneLine.prefix(n))) }
        // Longest first, so a shorter form doesn't leave part of a longer one.
        return Array(Set(out.filter { redactsLater($0) })).sorted { $0.count > $1.count }
    }

    /// Whether hidden text is also taken out of later results: not a key or
    /// two ("\n", "a"), which would blank half of every read.
    static func redactsLater(_ secret: String) -> Bool {
        secret.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    /// `text` with every occurrence of each secret (of at least 1 character)
    /// taken out, and where a read clipped a value partway through a secret
    /// ("…confidenti…"), that start of it too.
    public static func redact(_ text: String, secrets: [String]) -> String {
        var out = text
        // A secret that holds an ellipsis itself first, whole, so the
        // clipped pass doesn't take its own ellipsis for a cut.
        for s in secrets where s.contains("…") { out = out.replacingOccurrences(of: s, with: "(hidden)") }
        // Clipped next: a shorter secret replaced first could break up the
        // start of a longer one just before the ellipsis.
        if out.contains("…") { out = redactClipped(out, secrets: secrets.filter(redactsLater)) }
        for s in secrets where !s.isEmpty { out = out.replacingOccurrences(of: s, with: "(hidden)") }
        return out
    }

    /// The most a read keeps of a value before "…" (`AXSnapshot.clean`).
    static let longestClip = 160

    /// Where a read clipped a value partway through a secret ("…aaaconfidenti…"),
    /// the start of the secret right before each ellipsis is replaced. Only
    /// the text just before each ellipsis is looked at, up to `longestClip`.
    static func redactClipped(_ text: String, secrets: [String]) -> String {
        guard !secrets.isEmpty else { return text }
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "…" else { i += 1; continue }
            var best = 0
            for s in secrets {
                let sc = Array(s.prefix(longestClip))
                // The longest start of `s` (3+ characters, short of all of it) that ends at i.
                var k = min(sc.count - (sc.count == s.count ? 1 : 0), i)
                while k >= 3 {
                    if Array(chars[(i - k)..<i]) == Array(sc[0..<k]) { break }
                    k -= 1
                }
                if k >= 3 { best = max(best, k) }
            }
            if best > 0 {
                chars.replaceSubrange((i - best)..<i, with: Array("(hidden)"))
                i += 8 - best
            }
            i += 1
        }
        return String(chars)
    }

    /// A number from the agent, as a whole number when it is one that fits
    /// (`Int()` traps past Int's range, and JSON allows any finite number).
    static func num(_ v: Double?) -> String {
        guard let v else { return "0" }
        return v.isFinite && abs(v) < 1e15 ? "\(Int(v))" : "\(v)"
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
    private var hiddenSet: Set<String> = []
    /// The forms of each window's key run so far: replaced as the run grows,
    /// not piled up key by key.
    private var runForms: [UInt32: [String]] = [:]
    private var sortedCache: [String]?
    /// Every key run so far, as typed: a read answered while a run grew may
    /// show any start of it, so the starts are taken out of results too
    /// (worked out when needed, not stored as forms).
    private var pastRuns: [String] = []
    /// A hidden key was pressed with option: what it made (alone, or
    /// composed with the next key as an accent) can't be known, so later
    /// results lose every word with a character outside ASCII.
    private var optionKeys = false
    /// `text` with any start of a key run (3+ characters) taken out: found
    /// by where the run's first characters occur and how far each match
    /// goes, so a long run costs no more than the text it's looked for in.
    /// A key run's stand-in for a character it can't know (option makes
    /// one that depends on the layout): matches any character outside ASCII.
    static let anyCharacter: Character = "\u{FFFD}"

    /// `text` with, at each place, the longest of: a whole hidden text, or
    /// any start (3+ characters) of a key run, taken out. One pass over
    /// both, so neither can break up a longer match of the other ("con"
    /// typed key by key inside "confidential" typed as text).
    private func redactRunStarts(_ text: String) -> String {
        let text = optionKeys ? RecordingText.hideNonASCIIWords(text) : text
        let runs = (Array(keyRuns.values) + pastRuns).map(Array.init).filter { $0.count >= 3 }
        let whole = hiddenTexts.map(Array.init).filter { !$0.isEmpty }
        guard !runs.isEmpty || !whole.isEmpty else { return text }
        // The stand-in matches what option makes: a character outside ASCII.
        func same(_ a: Character, _ b: Character) -> Bool { b == Self.anyCharacter ? !a.isASCII : a == b }
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            var best = 0
            for w in whole where w.count > best && i + w.count <= chars.count && chars[i] == w[0] {
                if Array(chars[i..<(i + w.count)]) == w { best = w.count }
            }
            if i + 3 <= chars.count {
                for run in runs where same(chars[i], run[0]) && same(chars[i + 1], run[1]) && same(chars[i + 2], run[2]) {
                    var k = 3
                    while k < run.count, i + k < chars.count, same(chars[i + k], run[k]) { k += 1 }
                    best = max(best, k)
                }
            }
            if best > 0 {
                chars.replaceSubrange(i..<(i + best), with: Array("(hidden)"))
                i += 8
            } else {
                i += 1
            }
        }
        return String(chars)
    }
    /// All of it, longest first (a shorter one replaced first could break up
    /// a longer one that holds it).
    private var hiddenTexts: [String] {
        if let c = sortedCache { return c }
        let c = hiddenSet.union(runForms.values.joined()).sorted { $0.count > $1.count }
        sortedCache = c
        return c
    }
    private func addHidden(_ forms: [String]) {
        let before = hiddenSet.count
        hiddenSet.formUnion(forms)
        if hiddenSet.count != before { sortedCache = nil }
    }
    /// Characters hidden one press_key at a time, in a row: together they're
    /// what went into the field.
    private var keyRuns: [UInt32: String] = [:]
    /// Some typing was hidden under hide_typing: from then on, later reads
    /// show no field values at all (an edited or partly typed value matches
    /// no text that was typed).
    private var hidValues = false
    /// Something went into a password field: later reads show no field
    /// values (an edited copy, revealed by "show password", matches no
    /// typed text). Reads stay; names of other elements too.
    private var hideFieldValues = false
    /// When the first such write started: results that ended after it get
    /// the same masking again at export (one could end before the write did).
    private var hideFieldValuesFrom = Double.infinity
    /// When that started (ms into the video): reads that end after it are left out.
    private var hidValuesFrom = Double.infinity
    /// What a read's result becomes once typing is hidden.
    static let readLeftOut = "(Left out: once typed text is hidden, what windows show is left out of this recording's lists.)"
    static let reads: Set<String> = ["get_window_state", "screenshot", "status", "list_windows", "list_apps", "guard_report"]
    public let redactAll: Bool
    private let clock: () -> Double

    /// `clock`: milliseconds since the video started.
    public init(redactAll: Bool, clock: @escaping () -> Double) {
        self.redactAll = redactAll
        self.clock = clock
    }

    public var all: [RecordedStep] { lock.lock(); defer { lock.unlock() }; return steps }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return steps.count }

    static let foreignLeftOut = "(result left out: it typed in another session's window)"

    /// A tool call starts (or, inside a batch that's being recorded, one of its steps).
    /// `tracked`: what the session finds out while it runs (its target, where
    /// it lands) goes to it. A call answered off the session's queue
    /// (`status`, from another thread) isn't, so it never takes what belongs
    /// to the action running at the same time.
    @discardableResult
    /// `foreign`: run by another session, whose steps (a batch's too) this
    /// log never sees and whose fields it can't tell: anything it types is
    /// hidden, whatever the mode.
    public func begin(tool: String, args: JSONObject, inBatch: Bool = false, tracked: Bool = true, foreign: Bool = false) -> RecordedStep {
        lock.lock(); defer { lock.unlock() }
        var foreignTyping = false
        if foreign {
            let calls = [(tool, args)] + ((args["actions"] as? [Any]) ?? []).compactMap { $0 as? JSONObject }
                .map { (($0["tool"] as? String) ?? "", ($0["args"] as? JSONObject) ?? $0) }
            for (t, c) in calls {
                for key in ["text", "value"] { if let v = c[key] as? String, RecordingText.redactsLater(v) { addHidden(RecordingText.forms(of: v)) } }
                if t == "type_text" || t == "set_value" || (t == "press_key" && RecordedStep.typesACharacter(c)) { foreignTyping = true }
            }
        }
        if foreignTyping {
            // Its later reads can show it too.
            if redactAll {
                hidValuesFrom = min(hidValuesFrom, clock())
                hidValues = true
            } else {
                hideFieldValuesFrom = min(hideFieldValuesFrom, clock())
                hideFieldValues = true
            }
        }
        var a = args
        a["_session"] = nil
        a["_recording_dir"] = nil
        var original: [String: String] = [:]
        let modifiers = (a["modifiers"] as? [Any] ?? []).map { "\($0)" }
        for key in ["text", "value", "key"] { if let v = a[key] as? String { original[key] = v } }
        let character = tool == "press_key" && RecordedStep.typesACharacter(a)
        // Under hide_typing, what a call types is hidden from everything from
        // the moment it starts: a status answered meanwhile can show it already.
        if redactAll, tool == "type_text" || tool == "set_value" || character {
            for v in original.values where RecordingText.redactsLater(v) { addHidden(RecordingText.forms(of: v)) }
            hidValuesFrom = min(hidValuesFrom, clock())
            hidValues = true
        }
        let window = (a["window_id"] as? NSNumber)?.uint32Value
        // Text hidden earlier can come back in a later call (a path with the
        // file name that was typed): it's taken out of the arguments too.
        if !hiddenTexts.isEmpty { a = Self.redacted(a, hiddenTexts) as? JSONObject ?? a }
        if inBatch, let parent = open.last(where: { $0.sub == nil && $0.tool == "batch" }) {
            let s = RecordedStep(n: parent.n, sub: parent.steps.count + 1, tool: tool, args: a, t: clock())
            s.original = original
            s.typesCharacter = character
            s.window = window
            s.originalModifiers = modifiers
            s.multiField = RecordedStep.reachesAnotherField(original["text"] ?? "")
            parent.steps.append(s)
            open.append(s)
            return s
        }
        // A batch's steps are listed one by one, each with what it typed
        // hidden where it has to be: its arguments keep only how many.
        if tool == "batch" { a["actions"] = (a["actions"] as? [Any])?.count ?? 0 }
        let s = RecordedStep(n: steps.count + 1, sub: nil, tool: tool, args: a, t: clock())
        s.original = original
        s.typesCharacter = character
        s.window = window
        s.originalModifiers = modifiers
        s.multiField = RecordedStep.reachesAnotherField(original["text"] ?? "")
        s.foreignTyping = foreignTyping
        steps.append(s)
        if tracked { open.append(s) }
        return s
    }

    /// The step under way (the innermost one).
    private var current: RecordedStep? { open.last }

    public func setTarget(_ target: StepTarget) {
        lock.lock(); defer { lock.unlock() }
        // An element can be named after text hidden earlier (a row with the file name typed).
        // A text field's name can be its (edited) contents, once typing was hidden.
        let textInput = target.secure || ["TextField", "SecureTextField", "TextArea", "SearchField", "ComboBox"].contains(target.role)
        // Once typing is hidden, no name at all: any element's can echo it.
        // After a password write, a text field's name can be an edited copy of it too.
        let label = (hidValues || (hideFieldValues && textInput)) && !target.label.isEmpty && target.label != "focused field"
            ? "(hidden)" : RecordingText.redact(redactRunStarts(target.label), secrets: hiddenTexts)
        current?.target = StepTarget(element: target.element, role: target.role, label: label, frame: target.frame, secure: target.secure)
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

    /// Where typing without `element` goes was looked at: `secure` if a password field.
    public func setField(_ element: AXUIElement) {
        lock.lock(); defer { lock.unlock() }
        current?.field = element
    }

    /// Password fields hidden typing went into (without hide_typing), by
    /// step number, to cover where each is in every frame.
    /// Hidden typing (default mode), or typing into a password field still running.
    static func secureWrite(_ s: RecordedStep) -> Bool {
        s.textHidden || (s.end == nil && (s.target?.secure == true || s.focusSecure))
    }

    public func coverFields() -> [(String, AXUIElement)] {
        lock.lock(); defer { lock.unlock() }
        guard !redactAll else { return [] }
        // Running ones into a password field too: it can move before the write ends.
        return Self.flatten(steps).compactMap { s in Self.secureWrite(s) && !s.multiField ? s.field.map { (s.number, $0) } : nil }
    }

    public func setCover(_ rect: CGRect, window: CGWindowID? = nil) {
        lock.lock(); defer { lock.unlock() }
        current?.cover = rect
        if let window { current?.coverWindow = window }
    }

    /// Where each followed password field was when it was typed into.
    public func firstFieldFrames() -> [String: CGRect] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: CGRect] = [:]
        for s in Self.flatten(steps) { if let f = s.target?.frame, f.width > 0 { out[s.number] = f } }
        return out
    }

    /// Where each covered window was when its typing started (the first cover).
    public func firstCovers() -> [CGWindowID: CGRect] {
        lock.lock(); defer { lock.unlock() }
        var out: [CGWindowID: CGRect] = [:]
        for s in Self.flatten(steps) { if let w = s.coverWindow, let c = s.cover, out[w] == nil { out[w] = c } }
        return out
    }

    /// Windows hidden typing went into, to follow in the video.
    public func coverWindows() -> Set<CGWindowID> {
        lock.lock(); defer { lock.unlock() }
        // Without hide_typing, only hidden typing that could fill more than one field covers its window.
        // Without hide_typing, hidden typing into a password field covers that
        // field, following its window (and with a Tab, the whole window).
        guard redactAll else { return Set(Self.flatten(steps).filter(Self.secureWrite).compactMap(\.coverWindow)) }
        // Running ones too: the window can move while the typing goes on.
        return Set(Self.flatten(steps).filter { $0.textHidden || ($0.end == nil && $0.hidesText(redactAll: true)) }.compactMap(\.coverWindow))
    }

    public func setFocus(secure: Bool) {
        lock.lock(); defer { lock.unlock() }
        current?.focusChecked = true
        if secure { current?.focusSecure = true }
    }

    public func setFocusSecure() {
        lock.lock(); defer { lock.unlock() }
        current?.focusChecked = true
        current?.focusSecure = true
    }

    /// The step ended with `result`. Typed text that's to be hidden goes
    /// from its arguments and result now, before anything is written.
    public func end(_ s: RecordedStep, result: String, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard s.end == nil else { return }
        s.end = clock()
        s.isError = isError
        let given = result
        // Field values first, on the result as given (a secret replaced
        // first could break up the `value="` it looks for), then text hidden
        // in an earlier step, wherever it shows up again.
        // Under hide_typing, once something was typed, a read is left out
        // whole: a window can echo typed text in more ways (titles, labels,
        // layouts) than can be matched.
        // What a call run by another session returns after typing there can
        // echo it in more ways than its arguments show (keys one by one).
        var result = s.foreignTyping ? Self.foreignLeftOut
            : hidValues && Self.reads.contains(s.tool) ? Self.readLeftOut
            : (hidValues || hideFieldValues ? RecordingText.hideTitles(RecordingText.hideValues(result)) : result)
        result = RecordingText.redact(redactRunStarts(result), secrets: hiddenTexts)
        if s.hidesText(redactAll: redactAll) {
            let key = s.tool == "type_text" ? "text" : s.tool == "press_key" ? "key" : "value"
            if s.args[key] is String, let secret = s.original[key] ?? s.args[key] as? String {
                // What the field took can differ from what was asked (a mask,
                // a length limit): the result quotes it, and a later read shows it.
                let accepted = RecordingText.quotedSpans(given).filter { RecordingText.redactsLater($0) }
                result = RecordingText.hideQuoted(RecordingText.redact(result, secrets: [secret]))
                for a in accepted { addHidden(RecordingText.forms(of: a)) }
                s.args[key] = "(hidden, \(secret.count) characters)"
                s.secret = secret
                s.textHidden = true
                if RecordingText.redactsLater(secret) { addHidden(RecordingText.forms(of: secret)) }
                // Typing that stopped partway left part of it in the field,
                // which a later read shows.
                if isError {
                    for part in RecordingText.partsTyped(secret, result: result) where RecordingText.redactsLater(part) {
                        addHidden(RecordingText.forms(of: part))
                    }
                }
                // Longest first, every time: a shorter secret replaced first
                // would break up a longer one that holds it ("Ada" in "Ada Lovelace").
            }
        }
        // Keys pressed one by one add up to text in a field.
        let w = s.window ?? 0
        if s.tool == "press_key" && s.textHidden && !isError, let key = s.secret {
            // What it put in the field (a key refused or failed put nothing):
            // shift makes a capital, or the symbol over a digit or mark.
            let shifted = s.originalModifiers.contains { KeyMap.modifierNames["\($0)".trimmingCharacters(in: .whitespaces).lowercased()] == .maskShift }
            var ch = key
            if shifted, let c = key.first {
                ch = KeyMap.shifted.first { $0.value == c }.map { String($0.key) } ?? key.uppercased()
            }
            // Option makes a character the layout decides (option+s is ß):
            // a stand-in that matches whatever it was.
            if s.originalModifiers.contains(where: { KeyMap.modifierNames["\($0)".trimmingCharacters(in: .whitespaces).lowercased()] == .maskAlternate }) {
                ch = String(Self.anyCharacter)
                optionKeys = true
            }
            keyRuns[w, default: ""] += ch
            if let run = keyRuns[w], RecordingText.redactsLater(run) {
                runForms[w] = RecordingText.forms(of: run)
                sortedCache = nil
            }
        } else if Self.endsKeyRun.contains(s.tool) || (s.tool == "press_key" && !s.typesCharacter) {
            // Something that changes the input or where it goes; reads don't.
            if let run = keyRuns[w] { pastRuns.append(run) }
            keyRuns[w] = nil
            // The run is over: its whole text stays hidden, once.
            if let forms = runForms.removeValue(forKey: w) { addHidden(forms) }
        }
        if s.textHidden && !redactAll && (s.target?.secure == true || s.focusSecure) {
            hideFieldValuesFrom = min(hideFieldValuesFrom, s.t)
            hideFieldValues = true
        }
        if s.textHidden && redactAll {
            hidValuesFrom = min(hidValuesFrom, s.t)
            hidValues = true
        }
        s.original = [:]
        // A batch ends with a read of the window (its `state`): left out too.
        if s.tool == "batch", hidValues, let cut = result.range(of: "\n\n") {
            result = String(result[..<cut.lowerBound]) + "\n\n" + Self.readLeftOut
        }
        if s.tool == "batch" {
            result = RecordingText.redact(result, secrets: s.steps.compactMap(\.secret))
            // A step's line may quote part of what it typed (typing that
            // stopped partway says what went in): hide the quotes in the
            // lines of steps whose text is hidden.
            let hiddenSteps = Set(s.steps.filter { $0.secret != nil }.compactMap(\.sub))
            result = RecordingText.hideQuotedInSteps(result, hiddenSteps)
            for c in s.steps { c.secret = nil }
        }
        if s.sub == nil { s.secret = nil }
        s.result = result
        s.waits = RecordingText.waits(in: result)
        open.removeAll { $0 === s }
    }

    /// A step that already ended turned out otherwise (saving the recording
    /// it stopped failed): its result and whether it failed change.
    public func amend(_ s: RecordedStep, result: String, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        // Key runs first: a stored clipped form of one replaced first would
        // break up a longer start of it.
        s.result = RecordingText.redact(redactRunStarts(result), secrets: hiddenTexts)
        s.isError = isError
    }

    /// `value` with each secret taken out of every string in it, arrays and objects included.
    static func redacted(_ value: Any, _ secrets: [String]) -> Any {
        if let s = value as? String { return RecordingText.redact(s, secrets: secrets) }
        if let a = value as? [Any] { return a.map { redacted($0, secrets) } }
        if let o = value as? JSONObject { return o.mapValues { redacted($0, secrets) } }
        return value
    }

    static let endsKeyRun: Set<String> = ["click", "type_text", "set_value", "navigate", "open_window", "borrow_window", "release_window",
                                          "choose_file", "drag", "perform_action", "press_menu_item", "handoff", "take_back"]

    /// Every finished step's result and arguments redacted again against
    /// all text hidden by the end, before the lists are written: a call that
    /// ended before a later one hid its text (answered meanwhile) gets it too.
    public func redactAgain() {
        lock.lock(); defer { lock.unlock() }
        // Structural masking runs even with no remembered secret (a short one isn't kept).
        guard !hiddenTexts.isEmpty || !keyRuns.isEmpty || !pastRuns.isEmpty || hidValues || hideFieldValues else { return }
        for s in Self.flatten(steps) where s.end != nil {
            if hidValues, Self.reads.contains(s.tool), (s.end ?? 0) >= hidValuesFrom { s.result = Self.readLeftOut; continue }
            if (s.end ?? 0) >= min(hidValuesFrom, hideFieldValuesFrom) { s.result = RecordingText.hideTitles(RecordingText.hideValues(s.result)) }
            s.result = RecordingText.redact(redactRunStarts(s.result), secrets: hiddenTexts)
            s.args = Self.redacted(s.args, hiddenTexts) as? JSONObject ?? s.args
            if let t = s.target {
                s.target = StepTarget(element: t.element, role: t.role, label: RecordingText.redact(t.label, secrets: hiddenTexts), frame: t.frame, secure: t.secure)
            }
        }
    }

    /// Every step, batch steps after their batch, in the order they started.
    /// In the order they started: a call answered off the session's queue
    /// (status) can start while a batch's steps are running.
    public static func flatten(_ steps: [RecordedStep]) -> [RecordedStep] {
        steps.flatMap { [$0] + $0.steps }.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
    }
}
