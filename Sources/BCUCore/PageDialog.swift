import AppKit
import ApplicationServices

/// A web page's own dialog in a browser window, waiting for an answer.
///
/// Safari shows them two ways (measured on macOS 26, Safari 26):
/// - "Are you sure you want to leave this page?" (a page's beforeunload, as
///   the agent's step leaves the page or closes its tab) is a window of its
///   own, subrole AXDialog, with Stay on Page and Leave Page. It isn't a
///   sheet of the browser window, so it's found among the app's windows: one
///   over the agent's window, or one the session caught for it (it can show
///   on the user's screen first, see `WindowManager.watchdog`).
/// - alert(), confirm() and prompt() are drawn in the tab: a group with
///   subrole AXDialog under the window's tab group, in place of the web area.
///
/// Either way the page doesn't go on until it's answered, so an agent has to
/// see it first, and a step that left it showing has to say so.
enum PageDialog {
    static let windowSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    /// Browsers whose steps are watched for a page dialog they raise.
    /// Chromium's "Leave site?" is answered as it comes (see `LeaveWatch`).
    static func watches(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.SafariTechnologyPreview")
    }

    /// How long after a step it looks for a dialog the step raised.
    static let stepWaitMs = 350.0

    /// Steps that can leave a page, close a tab or press a page's button.
    static let watchedTools: Set<String> = ["click", "type_text", "press_key", "perform_action", "press_menu_item"]

    /// The dialog windows of `pid` over the window with `frame` (not the
    /// window itself), plus the ones in `caught` (the session's caught
    /// windows of that app, which may not have reached it yet).
    static func windows(pid: pid_t, over frame: CGRect?, window id: CGWindowID, caught: Set<CGWindowID> = []) -> [AXUIElement] {
        AX.windows(pid).filter { other in
            guard let subrole = AX.string(other, "AXSubrole"), windowSubroles.contains(subrole) else { return false }
            let wid = AX.windowID(other)
            if wid == id { return false }
            if let wid, caught.contains(wid) { return true }
            guard let frame, let f = AX.frame(other), f.width > 4, f.height > 4 else { return false }
            return f.intersects(frame)
        }
    }

    /// A page's dialog drawn in the window (alert, confirm, prompt): a
    /// group with subrole AXDialog among the window's containers, never
    /// inside the web area (a page's own role="dialog" is part of it).
    static func inWindow(_ window: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func look(_ el: AXUIElement, _ depth: Int) {
            guard depth < 5 else { return }
            for child in AX.children(el) {
                let role = AX.string(child, "AXRole") ?? ""
                if role == "AXGroup" && AX.string(child, "AXSubrole") == "AXDialog" { out.append(child); continue }
                if containers.contains(role) { look(child, depth + 1) }
            }
        }
        look(window, 0)
        return out
    }
    private static let containers: Set<String> = ["AXSplitGroup", "AXTabGroup", "AXGroup"]

    /// A window's page dialogs. While a dialog window is up, the page
    /// behind it is held and every accessibility read that reaches into it
    /// waits out a timeout (1.5 s on macOS 26), so the tab isn't looked in
    /// then: it can't show a dialog of its own meanwhile.
    static func all(pid: pid_t, window: AXUIElement, id: CGWindowID, caught: Set<CGWindowID> = []) -> [AXUIElement] {
        let over = windows(pid: pid, over: AX.frame(window), window: id, caught: caught)
        return over.isEmpty ? inWindow(window) : over
    }

    /// What a dialog says: the page's message, without Safari's "JavaScript"
    /// title line. An in-tab dialog carries the message as its value.
    static func message(_ dialog: AXUIElement) -> String {
        var texts = WindowManager.texts(in: dialog)
        if let v = AX.string(dialog, "AXValue"), !v.isEmpty { texts.append(v) }
        return message(texts: texts)
    }

    /// Each text is cut to `textLimit` characters, as the window's static
    /// texts are (`WindowManager.texts`), and the whole to `messageLimit`: a
    /// page's message can be any length, and it goes into every state header,
    /// step note and log line while the dialog waits.
    static let textLimit = 160
    static let messageLimit = 320

    static func message(texts: [String]) -> String {
        let kept = texts.map { text -> String in
            let line = text.prefix(textLimit * 2).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return String(line.prefix(textLimit)).trimmingCharacters(in: .whitespaces)
        }
            .filter { !$0.isEmpty && $0 != "JavaScript" }
        var seen = Set<String>()
        let unique = kept.filter { seen.insert($0).inserted }
        // A text that starts another one (a static text's cut copy of the
        // dialog's value) is said once, by the other.
        let said = unique.enumerated().filter { i, t in
            !unique.enumerated().contains { j, other in j != i && other.count > t.count && other.hasPrefix(t) }
        }.map(\.element).joined(separator: " ")
        return said.count > messageLimit ? String(said.prefix(messageLimit - 1)) + "…" : said
    }

    /// The session's caught windows of `pid` a page dialog can be among:
    /// not one handed off to the user or on their screen (a dialog handed
    /// to them is theirs to answer, not part of another window's state).
    static func caughtIDs(_ windows: [AgentWindow], pid: pid_t) -> Set<CGWindowID> {
        Set(windows.filter { $0.pid == pid && $0.kind == .caught && !$0.handedOff && !$0.withUser }.map(\.id))
    }

    static func buttons(_ dialog: AXUIElement) -> [String] {
        WindowManager.buttons(in: dialog).map(\.title)
    }

    /// The note a step's result gets when it left a dialog of the page
    /// showing.
    static func stepNote(message: String, buttons: [String], window id: CGWindowID) -> String {
        let said = message.isEmpty ? "" : " \"\(message)\""
        let choices = buttons.isEmpty ? "" : " (\(buttons.joined(separator: " / ")))"
        let held = isLeave(buttons: buttons)
            ? "Nothing has left or closed yet: the page stays as it is until it's answered."
            : "The page waits until it's answered."
        return "\n[page] The page in window \(id) is asking\(said)\(choices). \(held) get_window_state window_id=\(id) lists the dialog first: click one of its buttons."
    }

    /// The line a window's state starts with while a page dialog waits:
    /// `buttons` are each button's number in the listing and its title.
    static func stateLine(message: String, buttons: [(index: Int, title: String)]) -> String {
        let said = message.isEmpty ? "" : " \"\(message)\""
        let choices = buttons.map { "[\($0.index)] \($0.title)" }.joined(separator: ", ")
        return "A dialog from the page is waiting for an answer\(said)\(choices.isEmpty ? "" : ": \(choices)"). The page takes no input until it's answered."
    }

    /// A page asking whether to leave it: Chromium's "Leave site?" (Leave,
    /// Cancel) or Safari's "Are you sure you want to leave this page?"
    /// (Stay on Page, Leave Page). The title of the button that leaves.
    static func leaveButton(_ buttons: [String]) -> String? {
        guard buttons.count <= 4 else { return nil }
        if buttons.contains("Leave"), buttons.contains("Cancel") { return "Leave" }
        if buttons.contains("Leave Page"), buttons.contains("Stay on Page") { return "Leave Page" }
        return nil
    }

    static func isLeave(buttons: [String]) -> Bool { leaveButton(buttons) != nil }
}
