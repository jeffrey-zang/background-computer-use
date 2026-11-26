import AppKit
import ApplicationServices

/// Notices changes to the agent's windows that BCU didn't make.
///
/// Any process the user gave Accessibility (another computer-use tool, a
/// script) can find the agent's windows, read them, set a field's value or
/// press a button. macOS has no way to stop that for another app's windows.
/// What BCU can do is notice: it watches each app it has windows in for
/// value and focus changes, and one that lands in an agent window while
/// the agent isn't acting (no call running, and none for a moment) is
/// reported in the agent's next step result and in `guard_report`.
///
/// Reads leave no trace, so they can't be noticed. A change the app makes
/// by itself (a page script filling a field) looks the same as one from
/// another tool, so the report says "something other than BCU".
final class InterferenceWatch {
    struct Change: Equatable {
        let ms: Double
        let window: CGWindowID
        let app: String
        let what: String
        /// The same element and kind of change: coalesced.
        var key: String = ""
    }

    /// Accessibility notifications watched on each app.
    static let notifications = [kAXValueChangedNotification, kAXFocusedUIElementChangedNotification]
    /// Controls whose value the user (or a tool) sets. Text a page shows,
    /// progress bars and the like change by themselves all the time.
    static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXCheckBox",
                                          "AXRadioButton", "AXSlider", "AXPopUpButton", "AXSecureTextField", "AXIncrementor"]
    /// Changes this soon after one of BCU's own calls are taken as its own:
    /// an app answers a step a little after it.
    static let graceMs = 1500.0
    /// One report per window and element kind this often.
    static let coalesceMs = 2000.0

    /// What a notification on an agent window amounts to, or nil when it's
    /// BCU's own doing or nothing worth reporting. `idleMs`: how long since
    /// the session's last call ended (0 while one runs). `appIsFront`: the
    /// user is in that app, where their own clicks and keys move focus.
    static func describe(notification: String, role: String?, subrole: String?, title: String?, value: String?,
                         idleMs: Double, appIsFront: Bool, withUser: Bool) -> String? {
        guard idleMs >= graceMs, !withUser else { return nil }
        let name = elementName(role: role, subrole: subrole, title: title)
        switch notification {
        case kAXValueChangedNotification:
            guard let role, inputRoles.contains(role) else { return nil }
            if role == "AXSecureTextField" { return "\(name)'s value was changed" }
            guard let value else { return "\(name)'s value was changed" }
            return "\(name)'s value was changed to \"\(clip(value))\""
        case kAXFocusedUIElementChangedNotification:
            // The user's own clicks and keys move focus in the app they're in.
            guard !appIsFront else { return nil }
            return "focus was moved to \(name)"
        default:
            return nil
        }
    }

    static func elementName(role: String?, subrole: String?, title: String?) -> String {
        let kind: String
        switch role ?? "" {
        case "AXTextArea": kind = "a text area"
        case "AXTextField", "AXSearchField", "AXComboBox": kind = subrole == "AXSearchField" ? "a search field" : "a text field"
        case "AXSecureTextField": kind = "a password field"
        case "AXCheckBox": kind = "a checkbox"
        case "AXRadioButton": kind = "a radio button"
        case "AXSlider": kind = "a slider"
        case "AXPopUpButton": kind = "a pop-up menu"
        case "AXButton": kind = "a button"
        case "AXWebArea": kind = "the page"
        case "": kind = "an element"
        default: kind = "an element (\(role!))"
        }
        if let title, !title.isEmpty { return "\(kind) \"\(clip(title, 40))\"" }
        return kind
    }

    static func clip(_ s: String, _ n: Int = 80) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// Keeps one change per window and element within `coalesceMs` (one
    /// write fires several notifications), the newest text winning.
    struct Ledger {
        private(set) var pending: [Change] = []

        mutating func add(_ c: Change) {
            if let i = pending.lastIndex(where: { $0.window == c.window && $0.key == c.key }), c.ms - pending[i].ms < InterferenceWatch.coalesceMs {
                pending[i] = c
            } else {
                pending.append(c)
            }
            if pending.count > 20 { pending.removeFirst(pending.count - 20) }
        }

        mutating func take() -> [Change] {
            defer { pending = [] }
            return pending
        }
    }

    /// The text for the agent: one line per change, then what to do.
    static func report(_ changes: [Change], now: Date = Date(), nowMs: Double = BCUCore.nowMs()) -> String? {
        guard !changes.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let lines = changes.map { c -> String in
            let at = now.addingTimeInterval(-(nowMs - c.ms) / 1000)
            return "window \(c.window) (\(c.app)), \(f.string(from: at)): \(c.what)"
        }
        return "Something other than BCU changed your window while you weren't acting in it: "
            + lines.joined(separator: "; ")
            + ". Another tool with Accessibility access (another computer-use agent, a script) may be working in it, or the app did it by itself. Look at the window again (get_window_state) before you go on."
    }

    // MARK: Live

    private let lock = NSLock()
    private var ledger = Ledger()
    private var observers: [pid_t: AXObserver] = [:]
    private var watched: [CGWindowID: (pid: pid_t, app: String)] = [:]
    /// Asked on each notification (main thread): how long the session has
    /// been idle, and whether a window is with the user now.
    var idleMs: () -> Double = { .infinity }
    var withUser: (CGWindowID) -> Bool = { _ in false }
    /// Each change as it's noticed (main thread), for the guard report.
    var onChange: ((Change) -> Void)?

    /// Watch exactly these windows (the session's), from now on.
    func sync(_ windows: [AgentWindow]) {
        let want = Dictionary(windows.map { ($0.id, (pid: $0.pid, app: $0.appName)) }, uniquingKeysWith: { a, _ in a })
        lock.lock()
        let same = Set(want.keys) == Set(watched.keys)
        watched = want
        let pids = Set(want.values.map(\.pid))
        let have = Set(observers.keys)
        lock.unlock()
        guard !same || pids != have else { return }
        _ = onMainUnlessQuitting { [self] in
            for pid in pids.subtracting(observers.keys) { observe(pid) }
            for pid in Set(observers.keys).subtracting(pids) { unobserve(pid) }
        }
    }

    func stop() { sync([]) }

    /// Main thread.
    private func observe(_ pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, interferenceCallback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let app = AX.app(pid)
        for n in Self.notifications { AXObserverAddNotification(obs, app, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        lock.lock(); observers[pid] = obs; lock.unlock()
    }

    /// Main thread.
    private func unobserve(_ pid: pid_t) {
        lock.lock(); let obs = observers.removeValue(forKey: pid); lock.unlock()
        guard let obs else { return }
        let app = AX.app(pid)
        for n in Self.notifications { AXObserverRemoveNotification(obs, app, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    /// Main thread, from the observer.
    fileprivate func noticed(_ element: AXUIElement, _ notification: String) {
        let idle = idleMs()
        guard idle >= Self.graceMs else { return }
        AXUIElementSetMessagingTimeout(element, 0.25)
        let win = AX.element(element, "AXWindow") ?? (AX.string(element, "AXRole") == "AXWindow" ? element : nil)
        guard let win, let id = AX.windowID(win) else { return }
        lock.lock(); let entry = watched[id]; lock.unlock()
        guard let entry else { return }
        let role = AX.string(element, "AXRole")
        let value = notification == kAXValueChangedNotification ? AX.string(element, "AXValue") : nil
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid
        guard let what = Self.describe(notification: notification, role: role, subrole: AX.string(element, "AXSubrole"),
                                       title: AX.string(element, "AXTitle") ?? AX.string(element, "AXDescription"),
                                       value: value, idleMs: idle, appIsFront: front, withUser: withUser(id)) else { return }
        let change = Change(ms: nowMs(), window: id, app: entry.app, what: what,
                            key: "\(notification)|\(role ?? "")|\(CFHash(element))")
        lock.lock(); ledger.add(change); lock.unlock()
        onChange?(change)
    }

    /// The changes since the last call took them.
    func take() -> [Change] {
        lock.lock(); defer { lock.unlock() }
        return ledger.take()
    }
}

private func interferenceCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<InterferenceWatch>.fromOpaque(refcon).takeUnretainedValue().noticed(element, notification as String)
}
