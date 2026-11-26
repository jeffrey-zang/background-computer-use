import AppKit
import CPrivate

/// A cover over the whole agent display, so other apps' screenshots of
/// that display show the cover instead of the agent's windows.
///
/// The agent display is an ordinary online display: any app with Screen
/// Recording (another computer-use tool) can list it and capture it, and
/// macOS has no setting that keeps a display or another app's windows out
/// of a capture (`NSWindow.sharingType` is the window owner's to set, and
/// on macOS 15 and later ScreenCaptureKit ignores it anyway). What BCU can
/// do is put its own window on top of everything there: a capture of the
/// display then shows that window. BCU never reads the display that way:
/// it captures each window's own pixels, and its whole-display captures
/// (the user's preview) leave the cover out (`Shot`).
///
/// It doesn't stop a capture of one window by itself (ScreenCaptureKit's
/// window filter, `screencapture -l`): that reads the window's own pixels
/// whatever is in front of it.
///
/// The cover is never fully opaque: WindowServer counts an opaque window as
/// hiding what's under it, and apps whose windows are hidden stop drawing
/// (a page's timers and animations pause, a browser stops painting), so the
/// agent's screenshots would go stale. One window 99.9% opaque lets 1/1000
/// of what's under it through, and that's enough: stretching the contrast
/// of a capture (measured on macOS 26.1) made the agent's text readable.
/// So the cover is two such windows, one over the other: 1/1,000,000 gets
/// through, a ten-thousandth of one 8-bit step, and neither window alone is
/// opaque, so nothing under them counts as hidden.
public final class PrivacyCover {
    /// Window IDs of every cover, for code that lists or captures windows
    /// to leave them out.
    private static let idsLock = NSLock()
    private static var _ids: Set<CGWindowID> = []
    public static var ids: Set<CGWindowID> { idsLock.lock(); defer { idsLock.unlock() }; return _ids }
    public static func isCover(_ id: CGWindowID) -> Bool { idsLock.lock(); defer { idsLock.unlock() }; return _ids.contains(id) }

    /// Off with BCU_PRIVACY_COVER=0 (to compare, or if it ever gets in the way).
    static let enabled = ProcessInfo.processInfo.environment["BCU_PRIVACY_COVER"] != "0"
    /// Each layer is just under fully opaque: see the type's comment.
    static let alpha = 0.999
    static let layers = 2
    /// The share of what's under the cover that shows through it.
    static var transmission: Double { pow(1 - alpha, Double(layers)) }
    /// Above menus, popups and alerts on the display.
    static let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    private var panels: [NSPanel] = []
    private var displayID: CGDirectDisplayID = 0
    /// Counts `hide`s, so a `show` queued before one doesn't put the cover
    /// back after it.
    private let genLock = NSLock()
    private var generation = 0

    public init() {}

    /// The cover's frame in AppKit coordinates (bottom-left origin) for a
    /// display at `bounds` (global, top-left origin).
    static func cocoaFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// Put the cover over display `id`, or move it there. Any thread.
    public func show(on id: CGDirectDisplayID) {
        guard Self.enabled, id != 0 else { return }
        genLock.lock(); let gen = generation; genLock.unlock()
        DispatchQueue.main.async { [self] in
            genLock.lock(); let current = generation == gen; genLock.unlock()
            guard current, NSApp != nil else { return }
            let b = CGDisplayBounds(id)
            guard !b.isEmpty else { return }
            displayID = id
            if panels.isEmpty { panels = (0..<Self.layers).map { make(label: $0 == Self.layers - 1) } }
            let frame = Self.cocoaFrame(b, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
            // Back to front, so the labeled one is on top.
            for p in panels {
                if p.frame != frame { p.setFrame(frame, display: true) }
                p.orderFrontRegardless()
                let wid = CGWindowID(p.windowNumber)
                if wid > 0 { Self.idsLock.lock(); Self._ids.insert(wid); Self.idsLock.unlock() }
            }
            StreamWatch.shared.start()
        }
    }

    /// Follow the display after macOS moved it. Main thread.
    func follow() {
        guard !panels.isEmpty, displayID != 0 else { return }
        show(on: displayID)
    }

    /// Take the cover down. Any thread; on the main thread it's down when
    /// this returns. The display's owner calls it there just before taking
    /// the display away: a window still on a display that goes away is moved
    /// onto one of the user's, and this one would cover their screen.
    public func hide() {
        genLock.lock(); generation += 1; genLock.unlock()
        let work = { [self] in
            let gone = panels
            panels = []
            displayID = 0
            for p in gone {
                let wid = CGWindowID(p.windowNumber)
                Self.idsLock.lock(); Self._ids.remove(wid); Self.idsLock.unlock()
                p.orderOut(nil)
                p.close()
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func make(label withLabel: Bool) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: Self.alpha)
        p.hasShadow = false
        // A panel hides whenever its app stops being active (opening BCU's
        // Settings and switching away would take the cover down).
        p.hidesOnDeactivate = false
        // Nor when its app is hidden (Cmd-H in an app that runs the engine in process).
        p.canHide = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.level = Self.level
        p.title = "Background Computer Use: private agent display"
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        p.contentView = view
        guard withLabel else { return p }
        let label = NSTextField(labelWithString: "Private agent display\nBackground Computer Use keeps this display's windows out of other apps' screenshots.")
        label.alignment = .center
        label.textColor = NSColor(white: 1, alpha: 0.55)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return p
    }
}

/// Notices when something starts streaming the screen while agent
/// displays exist, for `guard_report`. macOS says only that a stream is
/// running (a screen recording, screen sharing, another tool's capture), not
/// which app or which display, and one-shot screenshots don't show at all.
/// A stream of a whole agent display sees its cover; one of a single window
/// doesn't.
final class StreamWatch {
    static let shared = StreamWatch()
    private var timer: DispatchSourceTimer?
    private var since: Double?
    private let queue = DispatchQueue(label: "bcu.streamwatch")

    /// What a change from `was` to `now` (streaming or not) amounts to, if anything.
    static func note(was: Bool, now: Bool, forMs: Double) -> String? {
        switch (was, now) {
        case (false, true):
            return "screen capture started: something on this Mac is streaming the screen (a screen recording, screen sharing, or another tool's capture; macOS doesn't say which app or display). A capture of a whole agent display shows BCU's cover; a capture of one window doesn't."
        case (true, false):
            return "screen capture ended after \(Int((forMs / 1000).rounded())) s"
        default:
            return nil
        }
    }

    /// Any thread. Polls once a second while an agent display is up.
    func start() {
        queue.async { [self] in
            guard timer == nil, BCUScreenWatcherPresent() >= 0 else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    private func tick() {
        let now = BCUScreenWatcherPresent() == 1
        let was = since != nil
        if let text = Self.note(was: was, now: now, forMs: since.map { nowMs() - $0 } ?? 0) {
            FocusGuard.shared?.record(text)
        }
        if now != was { since = now ? nowMs() : nil }
        if AgentDisplay.running.isEmpty && !now {
            timer?.cancel()
            timer = nil
        }
    }
}
