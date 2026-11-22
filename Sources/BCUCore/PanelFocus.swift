import AppKit
import CPrivate

/// macOS 15 only: while an open or save panel is its app's key window, the
/// panel's helper process (ViewBridgeAuxiliary) takes the system's keyboard
/// focus, whether that app is in front or not. With the panel over an
/// agent's window, what the user types in their own app goes to the agent's
/// panel instead: into Go to Folder in the middle of `choose_file`, which
/// then fails. Measured on 15.8: the helper has the keyboard from the picker
/// opening until it closes, letting go only for a few ms at a time. 26 and
/// 27 leave the keyboard with the app in front.
///
/// So on 15, while a `choose_file` step runs, the guard asks WindowServer
/// where each of the user's keys is going. While that's a panel helper, the
/// key and every one after it are held, and they're replayed in order the
/// moment the keyboard is back with the user's app (or the step is over):
/// for as long as the helper has it in the step, and never longer than
/// `maxHoldMs`.
public enum PanelFocus {
    static func applies(osMajor: Int) -> Bool { osMajor == 15 }
    static let onThisMac = applies(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    /// A hold never lasts longer than this (the guard's limit for any hold
    /// of all the user's input): then what was held goes on, and what the
    /// user types after it too, wherever the keyboard is.
    static let maxHoldMs = FocusGuard.maxHoldMs
    /// The helper lets go for a few ms and takes the keyboard again while a
    /// step works in the panel (1.5 to 7 ms measured): it's back with the
    /// user's app once it has stayed there this long.
    static let settleMs = 20.0
    /// The helper lets go a moment after the panel closes, which is when the
    /// step ends: keys are held for it this much longer at most.
    static let afterStepMs = 250.0

    /// Whether a user key about to go to `keyFocus` is held: a file is being
    /// chosen, and the key would go to a panel helper rather than the app in
    /// front. Not while one of the user's own panels is up: the keys may be
    /// theirs for it.
    static func holds(choosing: Bool, keyFocus: pid_t, front: pid_t, isHelper: Bool, userPanelOpen: Bool) -> Bool {
        choosing && keyFocus > 0 && keyFocus != front && isHelper && !userPanelOpen
    }

    /// Whether a `choose_file` step is on, or ended only just now.
    static func choosing(steps: Int, lastEndMs: Double, nowMs: Double) -> Bool {
        steps > 0 || nowMs - lastEndMs < afterStepMs
    }

    /// One hold, from its first key until the keyboard is back.
    struct Hold {
        let helper: pid_t
        let sinceMs: Double
        private(set) var backSinceMs: Double?

        init(helper: pid_t, sinceMs: Double) {
            self.helper = helper
            self.sinceMs = sinceMs
        }

        enum End: Equatable {
            /// The keyboard is back with the user's app.
            case back
            /// The step is over, with the helper still holding the keyboard
            /// (it failed, and the panel is still open).
            case stepOver
            /// `maxHoldMs` ran out with the helper still holding it.
            case expired
        }

        /// Fed where the keyboard is every few ms, and whether a file is
        /// still being chosen; says when the held keys go on.
        mutating func sample(helperHasKey: Bool, choosing: Bool, nowMs: Double) -> End? {
            if helperHasKey {
                backSinceMs = nil
            } else {
                let back = backSinceMs ?? nowMs
                backSinceMs = back
                if nowMs - back >= PanelFocus.settleMs { return .back }
            }
            if nowMs - sinceMs >= PanelFocus.maxHoldMs { return .expired }
            return choosing ? nil : .stepOver
        }
    }

    // MARK: Live

    private static let lock = NSLock()
    private static var helperCache: [pid_t: Bool] = [:]

    /// A process that serves panels: the helper that takes the keyboard
    /// (ViewBridgeAuxiliary) or the panel service itself.
    static func isHelper(_ pid: pid_t) -> Bool {
        lock.lock()
        if let known = helperCache[pid] { lock.unlock(); return known }
        lock.unlock()
        var buf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        let yes = (path as NSString).lastPathComponent == "ViewBridgeAuxiliary" || Panel.isPanelService(pid)
        lock.lock(); helperCache[pid] = yes; lock.unlock()
        return yes
    }

    /// Whether one of the user's own panels is up: a panel service window
    /// shown on one of their displays.
    private static func userPanelOpen() -> Bool {
        WindowList.all(onScreenOnly: true).contains { w in
            w.alpha > 0 && w.bounds.width > 64 && Panel.isPanelService(w.pid)
                && AgentDisplay.fenced(at: CGPoint(x: w.bounds.midX, y: w.bounds.midY)) == nil
        }
    }

    /// The panel helper with the keyboard, if a user's key would go to it
    /// while a file is being chosen.
    static func helperWithKey(front: pid_t) -> pid_t? {
        let key = BCUKeyFocusPID()
        guard key > 0, key != front, isHelper(key) else { return nil }
        let user = userPanelOpen()
        if user { Log.info("guard: a file panel helper (pid \(key)) has the keyboard, but one of the user's own panels is up: not held") }
        return holds(choosing: true, keyFocus: key, front: front, isHelper: true, userPanelOpen: user) ? key : nil
    }
}
