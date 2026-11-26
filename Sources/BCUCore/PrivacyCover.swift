import AppKit

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
/// The cover's color is 99.9% opaque, not 100%: WindowServer counts an
/// opaque window as hiding what's under it, and apps whose windows are
/// hidden stop drawing (a page's timers and animations pause, a browser
/// stops painting), so the agent's screenshots would go stale. At 99.9%
/// nothing under it shows in a capture (measured on macOS 26.1: the same
/// pixel values over a white window and over the wallpaper).
public final class PrivacyCover {
    /// Window IDs of every cover, for code that lists or captures windows
    /// to leave them out.
    private static let idsLock = NSLock()
    private static var _ids: Set<CGWindowID> = []
    public static var ids: Set<CGWindowID> { idsLock.lock(); defer { idsLock.unlock() }; return _ids }
    public static func isCover(_ id: CGWindowID) -> Bool { idsLock.lock(); defer { idsLock.unlock() }; return _ids.contains(id) }

    /// Off with BCU_PRIVACY_COVER=0 (to compare, or if it ever gets in the way).
    static let enabled = ProcessInfo.processInfo.environment["BCU_PRIVACY_COVER"] != "0"
    /// Just under fully opaque: see the type's comment.
    static let alpha = 0.999
    /// Above menus, popups and alerts on the display.
    static let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    private var panel: NSPanel?
    private var displayID: CGDirectDisplayID = 0

    public init() {}

    /// The cover's frame in AppKit coordinates (bottom-left origin) for a
    /// display at `bounds` (global, top-left origin).
    static func cocoaFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// Put the cover over display `id`, or move it there. Any thread.
    public func show(on id: CGDirectDisplayID) {
        guard Self.enabled, id != 0 else { return }
        DispatchQueue.main.async { [self] in
            guard NSApp != nil else { return }
            let b = CGDisplayBounds(id)
            guard !b.isEmpty else { return }
            displayID = id
            let p = panel ?? make()
            panel = p
            let frame = Self.cocoaFrame(b, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
            if p.frame != frame { p.setFrame(frame, display: true) }
            p.orderFrontRegardless()
            let wid = CGWindowID(p.windowNumber)
            if wid > 0 { Self.idsLock.lock(); Self._ids.insert(wid); Self.idsLock.unlock() }
        }
    }

    /// Follow the display after macOS moved it. Main thread.
    func follow() {
        guard panel != nil, displayID != 0 else { return }
        show(on: displayID)
    }

    /// Take the cover down. Any thread.
    public func hide() {
        DispatchQueue.main.async { [self] in
            guard let p = panel else { return }
            panel = nil
            displayID = 0
            let wid = CGWindowID(p.windowNumber)
            Self.idsLock.lock(); Self._ids.remove(wid); Self.idsLock.unlock()
            p.orderOut(nil)
            p.close()
        }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: Self.alpha)
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.level = Self.level
        p.title = "Background Computer Use: private agent display"
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "Private agent display\nBackground Computer Use keeps this display's windows out of other apps' screenshots.")
        label.alignment = .center
        label.textColor = NSColor(white: 1, alpha: 0.55)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        p.contentView = view
        return p
    }
}
