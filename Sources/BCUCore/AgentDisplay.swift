import AppKit
import CoreGraphics
import CPrivate

/// An agent's private display. Each agent session gets its own. The first
/// touches the user's displays at a single corner (bottom-right of their
/// union) and each further one touches the one before it at its corner, so
/// the cursor can only reach them at one point, and the input tap fences
/// even that off.
///
/// Adding or removing a display makes macOS rearrange them all: the whole
/// screen stalls for a few hundred ms, every window is told its screen
/// changed, and windows the user moved since the last time the displays
/// were like this can jump back to where they were then. So a display a
/// session is done with isn't removed: it's set aside (`spares`) for the
/// next session, and only removed once none has wanted it for
/// `spareLifeMs`. A run of agents, one after another or a few at a time,
/// costs one rearrangement going in and one coming out.
public final class AgentDisplay {
    public private(set) var displayID: CGDirectDisplayID = 0
    /// Agent display bounds in global (top-left origin) coordinates.
    public private(set) var bounds: CGRect = .zero
    /// Union of the user's real displays.
    public private(set) var userBounds: CGRect = .zero

    public let width: Int
    public let height: Int
    public var onChange: (() -> Void)?

    /// Position in the staircase of agent displays (0 is next to the user's).
    public private(set) var slot = 0

    private var display: BCUVirtualDisplay?

    // MARK: All agent displays

    private final class Ref { weak var display: AgentDisplay?; init(_ d: AgentDisplay) { display = d } }
    private static let registryLock = NSLock()
    private static var registry: [Ref] = []

    /// The running agent displays, in staircase order.
    public static var running: [AgentDisplay] {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry.compactMap(\.display).filter(\.isRunning).sorted { $0.slot < $1.slot }
    }

    /// The lowest slot no running display uses.
    public static func freeSlot() -> Int {
        registryLock.lock()
        var used = Set(spares.map(\.slot))
        registryLock.unlock()
        used.formUnion(running.map(\.slot))
        return (0...).first { !used.contains($0) }!
    }

    /// Any agent display, by ID.
    public static func isAgentDisplay(_ id: CGDirectDisplayID) -> Bool {
        running.contains { $0.displayID == id }
    }

    /// The agent display a global point is on.
    public static func containing(_ p: CGPoint) -> AgentDisplay? {
        running.first { $0.liveBounds.contains(p) }
    }

    // MARK: Stray displays

    /// What every BCU virtual display reports to macOS (see VirtualDisplay.m).
    static let vendorID: UInt32 = 0xBC0F
    static let productID: UInt32 = 0xBC01

    static func isBCUDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID
    }

    private static var strayCache: (atMs: Double, ids: [CGDirectDisplayID]) = (-1, [])

    /// BCU displays this process didn't make: left behind by a copy of the
    /// app that crashed (macOS can keep them with no owner until logout).
    /// They're as invisible to the user as ours, so the cursor is fenced
    /// off them too. Cached briefly: the input tap asks on every mouse move.
    public static var strayIDs: [CGDirectDisplayID] {
        let now = nowMs()
        registryLock.lock()
        if now - strayCache.atMs < 250 { let ids = strayCache.ids; registryLock.unlock(); return ids }
        let ours = Set(registry.compactMap { $0.display?.displayID }).union(spares.map(\.id))
        registryLock.unlock()
        let ids = onlineDisplayIDs().filter { !ours.contains($0) && isBCUDisplay($0) }
        registryLock.lock()
        strayCache = (now, ids)
        registryLock.unlock()
        return ids
    }

    /// Every display the cursor must stay off: ours (spares too) and strays.
    public static var fencedBounds: [CGRect] {
        registryLock.lock()
        let spare = spares.map(\.id)
        registryLock.unlock()
        return running.map(\.liveBounds) + (spare + strayIDs).map { CGDisplayBounds($0) }
    }

    private static var fencedCache: (atMs: Double, rects: [CGRect], users: [CGRect]) = (-1, [], [])

    /// The fenced display a global point is on. The input tap asks on every
    /// mouse move, so the rects are worked out at most every 100 ms (and
    /// right away after a display comes or goes).
    public static func fenced(at p: CGPoint) -> CGRect? {
        let now = nowMs()
        registryLock.lock()
        if now - fencedCache.atMs < 100 {
            let c = fencedCache
            registryLock.unlock()
            return fenced(at: p, agents: c.rects, users: c.users)
        }
        registryLock.unlock()
        let rects = fencedBounds
        let users = userDisplayIDs().map { CGDisplayBounds($0) }
        registryLock.lock()
        fencedCache = (now, rects, users)
        registryLock.unlock()
        return fenced(at: p, agents: rects, users: users)
    }

    /// The fenced display `p` is on, unless it's also on one of the user's
    /// displays lying over that one (macOS wouldn't place it while the
    /// screens slept): there the cursor, clicks and scrolls are on their
    /// screen, where they belong.
    static func fenced(at p: CGPoint, agents: [CGRect], users: [CGRect]) -> CGRect? {
        guard let agent = agents.first(where: { $0.contains(p) }) else { return nil }
        return users.contains { $0.contains(p) && $0.intersects(agent) } ? nil : agent
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static var callbackInstalled = false

    // MARK: The user's windows across a rearrangement

    /// Where the user's windows were before the displays changed.
    public struct UserWindows {
        let frames: [(id: CGWindowID, pid: pid_t, bounds: CGRect)]
        let displays: Set<CGDirectDisplayID>
    }

    /// What watching the user's windows across a display change reads and
    /// does, so a test can stand in for the window list.
    protocol UserWindowAccess {
        /// The window's frame now (global, top-left origin); nil once it's gone.
        func frame(_ id: CGWindowID) -> CGRect?
        var userDisplays: Set<CGDirectDisplayID> { get }
        /// Where the pointer is while the left button is held; nil when it isn't.
        var dragPointer: CGPoint? { get }
        /// An agent has the window (`borrow_window`).
        func isAgents(_ id: CGWindowID) -> Bool
        /// `clearStaleTile`: false when it has to wait for the user to be in that app.
        func fixTile(pid: pid_t, id: CGWindowID, frame: CGRect) -> Bool
        /// `frame` is where the window was before the change, `now` where macOS put it.
        func fixTileLater(pid: pid_t, id: CGWindowID, frame: CGRect, now: CGRect)
    }

    struct LiveUserWindows: UserWindowAccess {
        func frame(_ id: CGWindowID) -> CGRect? {
            guard let b = WindowList.info(id)?.bounds, b != .zero else { return nil }
            return b
        }
        var userDisplays: Set<CGDirectDisplayID> { Set(AgentDisplay.userDisplayIDs()) }
        var dragPointer: CGPoint? {
            CGEventSource.buttonState(.hidSystemState, button: .left) ? CGEvent(source: nil)?.location ?? .zero : nil
        }
        func isAgents(_ id: CGWindowID) -> Bool { WindowManager.isRegistered(id) }
        func fixTile(pid: pid_t, id: CGWindowID, frame: CGRect) -> Bool { AgentDisplay.clearStaleTile(pid: pid, id: id, frame: frame) }
        func fixTileLater(pid: pid_t, id: CGWindowID, frame: CGRect, now: CGRect) {
            AgentDisplay.noteStaleTile(NotedTile(pid: pid, id: id, frame: frame, now: now))
        }
    }

    /// Note where the user's windows are before a display change
    /// (`noteUserWindows`) and watch them after it (`startWatchingUserWindows`).
    /// A window macOS moves then is left where macOS put it. Putting it back
    /// through accessibility made it jump again at the next change: on
    /// macOS 15 and 27 AppKit moves a window another process last moved through
    /// accessibility back to its frame from before that move, once, at the
    /// next display change (`_displayChangedSoAdjustWindows:`), so a window
    /// put back jumped at every agent display add and removal. The one move
    /// acted on is a stale tile's (below), through the app's own menu.
    public static func noteUserWindows() -> UserWindows {
        clearNotedStaleTiles()
        registryLock.lock()
        let spare = spares.map(\.id)
        registryLock.unlock()
        let agents = running.map(\.liveBounds) + spare.map { CGDisplayBounds($0) }
        let frames = WindowList.all().filter { w in
            w.layer == 0 && w.pid != getpid() && w.bounds.width > 40 && w.bounds.height > 40
                && !agents.contains { $0.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY)) }
        }.map { (id: $0.id, pid: $0.pid, bounds: $0.bounds) }
        return UserWindows(frames: frames, displays: Set(userDisplayIDs()))
    }

    // MARK: Stale tiles

    /// On macOS 26 and later a window the user tiled and then zoomed back to
    /// full size can keep its tile in WindowManager, which puts the window
    /// back in the tile at every display change (a full-height window drops
    /// to the top half). Nothing outside the app can change that tile, and
    /// the app's Return to Previous Size drops it by shrinking the window to
    /// its size from before the tile. Its Window > Fill gives the window the
    /// tile of the frame it has, so display changes leave it where it is.
    /// macOS only enables the item while the app is in front, and it acts on
    /// the main window: it's pressed when the user is in that app with that
    /// window; any other is kept (`noteStaleTile`) and tried again before
    /// the next display change.
    static let fillIdentifier = "_zoomFill:"

    private static func menuItem(_ pid: pid_t, identifier: String) -> AXUIElement? {
        guard let bar = AX.element(AX.app(pid), "AXMenuBar") else { return nil }
        // Menu bar item > menu > (Move & Resize > menu >) the item.
        func find(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            for child in AX.children(el) {
                if AX.string(child, "AXIdentifier") == identifier { return child }
                if depth > 0, let found = find(child, depth: depth - 1) { return found }
            }
            return nil
        }
        return find(bar, depth: 4)
    }

    /// What to do about the tile behind a window of the user's that macOS
    /// just moved at a display change.
    enum TileFix: Equatable {
        /// Nothing: no tile BCU can replace without changing the window.
        case nothing
        /// Press Window > Fill.
        case fill
        /// Not now (the user isn't in that app with that window): before the next display change.
        case later
    }

    /// `want` is where the window belongs, `visible` its screen's visible
    /// frame (global, top-left origin), `margins` whether tiled windows get
    /// margins. `front` is the app in front, `mainWindow` that app's main
    /// window. `untileEnabled` (whether the app says the window is tiled)
    /// doesn't count: on 27.3 the app doesn't know the tile WindowManager holds.
    static func tileFix(want: CGRect, visible: CGRect, margins: Bool, front: pid_t, pid: pid_t,
                        mainWindow: CGWindowID?, id: CGWindowID, untileEnabled: Bool) -> TileFix {
        // Fill puts the window at the visible frame (inset, with margins):
        // only for a window that's already there.
        let fills = !visible.isNull && abs(want.minX - visible.minX) <= 2 && abs(want.minY - visible.minY) <= 2
            && abs(want.width - visible.width) <= 2 && abs(want.height - visible.height) <= 2
        guard fills, !margins else { return .nothing }
        return front == pid && mainWindow == id ? .fill : .later
    }

    /// Whether WindowManager gives tiled windows margins (System Settings >
    /// Desktop & Dock > Tiled windows have margins).
    static var tileMargins: Bool {
        CFPreferencesCopyAppValue("EnableTiledWindowMargins" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
    }

    /// The visible frame (no menu bar or Dock) of the screen most of `rect`
    /// is on, in global top-left coordinates; nil when it's on none.
    static func visibleFrame(of rect: CGRect) -> CGRect? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let flipped = NSScreen.screens.map { s -> (CGRect, CGRect) in
            let f = s.frame, v = s.visibleFrame
            return (CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height),
                    CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height))
        }
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        guard let best = flipped.max(by: { area($0.0.intersection(rect)) < area($1.0.intersection(rect)) }),
              area(best.0.intersection(rect)) > 0 else { return nil }
        return best.1
    }

    /// Any thread but main isn't needed; never holds a lock. True when the
    /// tile was cleared (or the app says the window has none).
    @discardableResult
    static func clearStaleTile(pid: pid_t, id: CGWindowID, frame want: CGRect) -> Bool {
        guard WindowList.info(id)?.pid == pid else { return true }
        let main = AX.element(AX.app(pid), "AXMainWindow").flatMap { AX.windowID($0) }
        switch tileFix(want: want, visible: visibleFrame(of: want) ?? .null, margins: tileMargins, front: BCUFrontProcessPID(), pid: pid,
                       mainWindow: main, id: id, untileEnabled: false) {
        case .nothing: return true
        case .later: return false
        case .fill: break
        }
        guard let item = menuItem(pid, identifier: fillIdentifier), AX.bool(item, "AXEnabled") ?? false,
              AX.perform(item, "AXPress") == .success else { return false }
        Log.info("gave a window of the user's that fills its screen (pid \(pid), window \(id)) the Fill tile, so display changes leave it where it is")
        return true
    }

    private static let staleLock = NSLock()
    private static var staleTiles: [CGWindowID: NotedTile] = [:]

    /// A stale tile kept for later: the window's frame before the display
    /// change (`frame`) and where macOS put it (`now`).
    struct NotedTile {
        let pid: pid_t
        let id: CGWindowID
        let frame: CGRect
        let now: CGRect
    }

    /// The frame to decide a noted tile's fix by, given where the window
    /// is `current`ly; nil to forget it. Nothing puts the window back after
    /// macOS drops it into the tile, so it's judged by where it was before
    /// the change, while it's still where macOS put it. One the user has
    /// moved or resized since is theirs to keep.
    static func frameForNotedTile(_ t: NotedTile, current: CGRect) -> CGRect? {
        let same = abs(current.minX - t.now.minX) <= 2 && abs(current.minY - t.now.minY) <= 2
            && abs(current.width - t.now.width) <= 2 && abs(current.height - t.now.height) <= 2
        return same ? t.frame : nil
    }

    static func noteStaleTile(_ t: NotedTile) {
        staleLock.lock(); staleTiles[t.id] = t; staleLock.unlock()
    }

    /// Before a display change: clear what couldn't be cleared last time
    /// (the user wasn't in that app then).
    private static func clearNotedStaleTiles() {
        staleLock.lock(); let noted = staleTiles; staleLock.unlock()
        for (id, t) in noted {
            guard let current = WindowList.info(id)?.bounds, current != .zero,
                  let frame = frameForNotedTile(t, current: current) else {
                staleLock.lock(); staleTiles[id] = nil; staleLock.unlock()
                continue
            }
            if clearStaleTile(pid: t.pid, id: id, frame: frame) {
                staleLock.lock(); staleTiles[id] = nil; staleLock.unlock()
            }
        }
    }

    /// Any thread; returns at once and watches on a thread of its own for
    /// `quietMs` after the last window that moved (macOS moves them as the
    /// display comes online and again when it's placed), 5 s at most.
    public static func startWatchingUserWindows(_ before: UserWindows, quietMs: Double = 1800) {
        guard !before.frames.isEmpty else { return }
        let thread = Thread { watchUserWindows(before, quietMs: quietMs, access: LiveUserWindows()) }
        thread.name = "bcu.display.windows"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The calling thread; returns `quietMs` after the last move, 5 s at most.
    static func watchUserWindows(_ before: UserWindows, quietMs: Double, access: UserWindowAccess) {
        let deadline = nowMs() + 5000
        var lastMoved = nowMs()
        // Where each window was, unless the user has moved it since.
        var place: [CGWindowID: CGRect] = [:]
        for w in before.frames { place[w.id] = w.bounds }
        var last = place
        var dragged: [CGWindowID: (last: CGRect, changes: Int)] = [:]
        func differs(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) > 1 || abs(a.minY - b.minY) > 1 || abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1
        }
        while nowMs() < deadline && nowMs() - lastMoved < quietMs {
            sleepMs(15)
            // The user's own displays changed too (a monitor unplugged):
            // then where things were no longer says where they belong.
            guard access.userDisplays == before.displays else { return }
            // A window the user is dragging or resizing isn't macOS's
            // doing. Theirs is the one under the pointer that moves on
            // every look; what macOS does to a window is one jump or two.
            if let pointer = access.dragPointer {
                for w in before.frames {
                    guard let now = access.frame(w.id) else { continue }
                    var d = dragged[w.id] ?? (now, 0)
                    if now != d.last { d.changes += 1; d.last = now }
                    dragged[w.id] = d
                    if d.changes >= 3, now.insetBy(dx: -12, dy: -12).contains(pointer) { place[w.id] = now }
                }
                continue
            }
            dragged = [:]
            for w in before.frames {
                guard let now = access.frame(w.id) else { continue }
                if let l = last[w.id], differs(now, l) { lastMoved = nowMs() }
                last[w.id] = now
            }
        }
        // An agent has taken it since (`borrow_window` moves a window of
        // the user's onto its display): not the display change's doing.
        let moved = before.frames.filter { w in
            guard let was = place[w.id], let now = last[w.id] else { return false }
            return differs(now, was) && !access.isAgents(w.id)
        }
        guard !moved.isEmpty else { return }
        Log.info("macOS moved \(moved.count) of the user's windows when the displays changed; left where macOS put them")
        // A window that filled its screen and moved is usually one with a
        // tile macOS still holds though it has since gone back to full
        // size. Replace that, so the next display change leaves it alone.
        for w in moved {
            guard let was = place[w.id] else { continue }
            if !access.fixTile(pid: w.pid, id: w.id, frame: was), let now = last[w.id] {
                access.fixTileLater(pid: w.pid, id: w.id, frame: was, now: now)
            }
        }
    }

    // MARK: Spares

    /// A display no session is using, kept for the next one.
    private struct Spare {
        let display: BCUVirtualDisplay
        let id: CGDirectDisplayID
        let slot: Int
        let width: Int
        let height: Int
        let sinceMs: Double
    }
    private static var spares: [Spare] = []
    /// How long a display nobody uses is kept before it's removed.
    /// BCU_SPARE_DISPLAY_S at launch changes it (0: never kept).
    public static let spareLifeMs = (Double(ProcessInfo.processInfo.environment["BCU_SPARE_DISPLAY_S"] ?? "") ?? 300) * 1000

    /// Main thread. Remove spare displays nobody has wanted for
    /// `spareLifeMs`, or all of them (`all`: the engine is stopping, the
    /// Mac is going to sleep, or the user's own displays are gone).
    public static func reapSpares(all: Bool = false) {
        // Changing the displays stalls macOS for a moment (measured for
        // adding one: keys typed just then reach their app 60–100 ms late,
        // and 0.3–0.6 s late when several are added together), so a spare
        // isn't taken away while the user is typing. There's no hurry unless
        // an agent is waiting for a place; `tend` asks again every second.
        if !all, !someoneWaiting, let activity = FocusGuard.shared?.activity, QuietWait.typing(activity.snapshot, now: nowMs()) { return }
        let furthestInUse = running.map(\.slot).max() ?? -1
        registryLock.lock()
        let now = nowMs()
        var gone = spares.filter { all || now - $0.sinceMs > spareLifeMs }
        if !all {
            // The displays stand in a staircase, each at the corner of the one
            // before, and macOS won't leave a gap: take one out and every
            // display after it moves, with its windows, which on the way
            // land on the user's screen (measured on 0.1.18: an agent's
            // window at 135,212 on the main display for half a second when
            // three idle displays before its own were removed). So only from
            // the far end: never one with a display in use after it, or a
            // spare that's staying.
            gone.removeAll { $0.slot < furthestInUse }
            // Not with a window on it (an app put one there since): it would
            // land on the user's screen. Clean it up first (closed if an
            // agent's, else put on the user's screen); next time, then.
            let busy = gone.filter { !WindowManager.windows(on: CGDisplayBounds($0.id)).isEmpty }
            gone.removeAll { g in busy.contains { $0.id == g.id } }
            // (After the busy ones are held back: one of those staying means
            // the spares before it stay too.)
            while let blocked = gone.first(where: { g in spares.contains { s in s.slot > g.slot && !gone.contains { $0.id == s.id } } }) {
                gone.removeAll { $0.id == blocked.id }
            }
            for b in busy {
                let bounds = CGDisplayBounds(b.id)
                DispatchQueue.global(qos: .utility).async { WindowManager.closeLeftovers(on: bounds) }
            }
        }
        spares.removeAll { s in gone.contains { $0.id == s.id } }
        strayCache.atMs = -1; fencedCache.atMs = -1
        registryLock.unlock()
        guard !gone.isEmpty else { return }
        let before = noteUserWindows()
        for s in gone {
            Self.remove(s.id, disable: { _ = BCUDisableDisplay($0) }, release: s.display.invalidate)
            Log.info("agent display \(s.slot + 1) (\(s.id)) removed: no agent has needed it for a while")
        }
        for d in running { d.reconfigured() }
        startWatchingUserWindows(before)
    }

    /// Take display `id` away: `release` lets go of it, and macOS removes it.
    /// A display removed while enabled leaves a Window Server "Backstop"
    /// window behind until logout (one per agent session, hundreds after a
    /// few days; each one slows every window list that includes desktop
    /// elements). Disabled first, it leaves none of its own: the next
    /// display takes over the one there is.
    static func remove(_ id: CGDirectDisplayID, disable: (CGDirectDisplayID) -> Void, release: () -> Void) {
        disable(id)
        release()
    }

    /// Spare displays there are (for the status line and tests).
    public static var spareCount: Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return spares.count
    }

    // MARK: How many at once

    /// At most this many agent displays exist at once. An agent that needs
    /// one when they're all taken waits its turn (see `reserve`).
    /// BCU_MAX_DISPLAYS at launch changes it (for tests).
    public static let maxDisplays = max(1, Int(ProcessInfo.processInfo.environment["BCU_MAX_DISPLAYS"] ?? "") ?? 4)
    private static let gate = NSCondition()
    private static var reservations = 0
    /// Agents waiting for a display, first come first served.
    private static var waiting: [Int] = []
    private static var nextTicket = 0
    private var reserved = false

    /// Take one of the `maxDisplays` places for this display, waiting up to
    /// `timeout` for another agent's display to go away. `onWait` runs once
    /// if it has to wait. Never call it on the main thread. Returns false
    /// on a timeout.
    public func reserve(timeout: TimeInterval, onWait: () -> Void) -> Bool {
        let g = Self.gate
        g.lock()
        if reserved { g.unlock(); return true }
        let ticket = Self.nextTicket
        Self.nextTicket += 1
        Self.waiting.append(ticket)
        let deadline = Date().addingTimeInterval(timeout)
        var told = false
        while !(Self.waiting.first == ticket && Self.reservations < Self.maxDisplays) {
            if !told {
                told = true
                g.unlock(); onWait(); g.lock()
                continue
            }
            if !g.wait(until: deadline) {
                Self.waiting.removeAll { $0 == ticket }
                g.broadcast()
                g.unlock()
                return false
            }
        }
        Self.waiting.removeFirst()
        Self.reservations += 1
        reserved = true
        g.broadcast()
        g.unlock()
        return true
    }

    /// An agent is waiting for a display.
    public static var someoneWaiting: Bool {
        gate.lock(); defer { gate.unlock() }
        return !waiting.isEmpty
    }

    /// Give the place back (`stop` does).
    private func unreserve() {
        let g = Self.gate
        g.lock()
        if reserved {
            reserved = false
            Self.reservations -= 1
            g.broadcast()
        }
        g.unlock()
    }

    public static let defaultWidth = 1600
    public static let defaultHeight = 1000

    public init(width: Int = AgentDisplay.defaultWidth, height: Int = AgentDisplay.defaultHeight) {
        self.width = width
        self.height = height
    }

    public var isRunning: Bool { display != nil && displayID != 0 }

    /// Where the display is right now. Unlike `bounds`, this is never stale
    /// while macOS is rearranging displays (wake, a monitor plugged in).
    public var liveBounds: CGRect {
        let id = displayID
        return id == 0 ? .zero : CGDisplayBounds(id)
    }

    /// Not on the main thread (see `open`). `slot` picks the display's place
    /// in the staircase and its serial, which macOS keys remembered modes on.
    /// The display comes online asynchronously: follow with `waitUntilOnline`
    /// and then `finishStart`.
    public func start(slot: Int = AgentDisplay.freeSlot()) throws {
        guard display == nil else { return }
        // One a session before this left behind: nothing is added, so
        // nothing on the user's screens moves.
        Self.registryLock.lock()
        let spare = Self.spares.filter { $0.width == width && $0.height == height }.min { $0.slot < $1.slot }
        if let spare { Self.spares.removeAll { $0.id == spare.id } }
        Self.registryLock.unlock()
        if let spare, !CGDisplayBounds(spare.id).isEmpty {
            display = spare.display
            displayID = spare.id
            self.slot = spare.slot
            reused = true
            register()
            return
        }
        if let spare { Self.remove(spare.id, disable: { _ = BCUDisableDisplay($0) }, release: spare.display.invalidate) }
        reused = false
        Self.noteChange()
        self.slot = slot
        let name = slot == 0 ? "Agent Display" : "Agent Display \(slot + 1)"
        // macOS refuses a second display with a serial that's still online,
        // which a stray display from a crashed copy can hold until logout.
        // Spare serials sit past every slot's own.
        let base: UInt32 = 0x4243_5532
        let serials = [base + UInt32(slot)] + (1...8).map { base + UInt32(slot) + UInt32($0) * 16 }
        var made: BCUVirtualDisplay?
        for serial in serials {
            made = Self.makeVirtualDisplay(name, width, height, serial)
            if made != nil {
                if serial != serials[0] { Log.info("agent display serial \(String(serials[0], radix: 16)) taken; used \(String(serial, radix: 16))") }
                break
            }
        }
        guard let vd = made else {
            throw ToolError("could not create the virtual display")
        }
        display = vd
        displayID = vd.displayID
        register()
    }

    /// Makes the virtual display (a stand-in in tests): nil if macOS refused it.
    static var makeVirtualDisplay: (_ name: String, _ width: Int, _ height: Int, _ serial: UInt32) -> BCUVirtualDisplay? = { name, width, height, serial in
        BCUVirtualDisplay(name: name, width: UInt32(width), height: UInt32(height), ppi: 110, serial: serial)
    }

    /// Not on the main thread. Make the display (`start`), wait for it to
    /// come online and put it in place (`finishStart`), all on this thread.
    /// macOS tells every app's main thread of each display change and waits
    /// up to 0.25 s for its answer, BCU's too: made or placed on the main
    /// thread, that thread is stuck in the call and every change stalls for
    /// the whole wait (measured on macOS 27.0: about 280 ms per display
    /// added, and WindowServer logged the timeout each time). `onMain` runs
    /// work on the main thread (`stop`, on a failure), and throws when it
    /// can't (BCU is quitting).
    /// Every way out but success gives the display's place back (`stop`
    /// does, with or without a display): one kept would leave the next
    /// agent waiting for a display no one is using.
    public func open(onMain: (@escaping () -> Void) throws -> Void) throws {
        // A new display rearranges them all; note the user's windows to see
        // which macOS moves (a stale tile's gets its tile replaced).
        let userWindows = Self.noteUserWindows()
        do {
            try Self.making { try start() }
        } catch {
            try? onMain { self.stop(remove: true) }
            throw error
        }
        if !reused { Self.startWatchingUserWindows(userWindows) }
        guard waitUntilOnline() else {
            try? onMain { self.stop(remove: true) }
            throw ToolError("virtual display never came online")
        }
        Self.making { finishStart() }
    }

    /// Displays are made and placed one at a time, for every session (the
    /// main thread did that while they were made there). A display takes
    /// the first free slot and holds it only once it's made: two made at
    /// once would take the same slot, and two opens of one display would
    /// each make one.
    private static let makeLock = NSLock()
    private static func making<T>(_ work: () throws -> T) rethrows -> T {
        makeLock.lock(); defer { makeLock.unlock() }
        return try work()
    }

    /// Registered right away so a display starting at the same time
    /// (another session, while this one waits) takes another slot.
    private func register() {
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        Self.registry.append(Ref(self))
        Self.strayCache.atMs = -1; Self.fencedCache.atMs = -1
        if !Self.callbackInstalled {
            Self.callbackInstalled = true
            CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
        }
        Self.registryLock.unlock()
    }

    /// The display `start` gave this session was a spare, not a new one.
    public private(set) var reused = false

    /// Wait for the display started by `start` to come online. Call it off the
    /// main queue: on macOS 15 the display only comes online once the main
    /// queue is free, so waiting inside a main-queue block always times out.
    public func waitUntilOnline(timeout: TimeInterval = 5) -> Bool {
        let id = displayID
        let deadline = Date().addingTimeInterval(timeout)
        while CGDisplayBounds(id).isEmpty && Date() < deadline {
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) } else { sleepMs(20) }
        }
        return id != 0 && !CGDisplayBounds(id).isEmpty
    }

    /// Not on the main thread (see `open`), once the display is online.
    public func finishStart() {
        place(mode: retinaModeNeeded())
        Log.info("agent display \(slot + 1) (\(displayID)) at \(bounds.short)\(reused ? " (kept from an earlier session)" : ""); user displays \(userBounds.short)")
    }

    /// Main thread. The session is done with its display. It's set aside
    /// for the next session (see `spares`) unless `remove`, or there's no
    /// user display for it to sit beside.
    public func stop(remove: Bool = false) {
        defer { unreserve() }
        guard let vd = display else { return }
        display = nil
        let id = displayID
        displayID = 0
        bounds = .zero
        // Kept for the next agent, and in any case while an agent is at work
        // on a display after this one (see `reapSpares`): it holds its place.
        let holdsPlace = Self.running.contains { $0 !== self && $0.slot > slot }
        let keep = !remove && (Self.spareLifeMs > 0 || holdsPlace) && !CGDisplayBounds(id).isEmpty && !Self.userDisplayIDs().isEmpty
        Self.registryLock.lock()
        Self.registry.removeAll { $0.display == nil || $0.display === self }
        if keep { Self.spares.append(Spare(display: vd, id: id, slot: slot, width: width, height: height, sinceMs: nowMs())) }
        Self.strayCache.atMs = -1; Self.fencedCache.atMs = -1
        Self.registryLock.unlock()
        if keep {
            Log.info("agent display \(slot + 1) (\(id)) set aside for the next agent")
            return
        }
        let before = Self.noteUserWindows()
        Self.remove(id, disable: { _ = BCUDisableDisplay($0) }, release: vd.invalidate)
        Log.info("agent display \(slot + 1) (\(id)) removed")
        // The ones after it are checked: macOS may have moved them.
        for d in Self.running { d.reconfigured() }
        Self.startWatchingUserWindows(before)
    }

    /// The user's real displays: every active display that isn't an agent's.
    public func userDisplayIDs() -> [CGDirectDisplayID] {
        Self.userDisplayIDs()
    }

    /// The user's real displays: every active display that isn't a BCU
    /// one. While all of them sleep none is active, so then the online ones,
    /// which keep their places.
    public static func userDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        let agents = Set(running.map(\.displayID))
        let active = Array(ids.prefix(Int(count))).filter { !agents.contains($0) && !isBCUDisplay($0) }
        if !active.isEmpty { return active }
        return onlineDisplayIDs().filter { !agents.contains($0) && !isBCUDisplay($0) }
    }

    /// Where this display goes: at the bottom-right corner of the agent
    /// display before it, or of the user's displays for the first (see
    /// `corner`), unless another display is in the way (see `spot`). nil
    /// when there's nowhere to put it (no user display at all).
    private func anchor() -> CGPoint? {
        let layout = Self.layout(excluding: displayID)
        let preferred: CGPoint
        if let before = Self.running.filter({ $0.slot < slot && $0 !== self }).last {
            let b = CGDisplayBounds(before.displayID)
            preferred = CGPoint(x: b.maxX, y: b.maxY)
        } else {
            guard let c = Self.corner(of: layout.user) else { return nil }
            preferred = c
        }
        return Self.spot(size: CGSize(width: width, height: height), preferred: preferred, user: layout.user, others: layout.others)
    }

    /// The displays around agent display `id`: the user's own (`user`, the
    /// ones it's placed by), and every other online display (`others`: the
    /// user's, BCU's other displays and spares, strays, and other apps'
    /// virtual displays), which it must not cover.
    private static func layout(excluding id: CGDirectDisplayID) -> (user: [CGRect], others: [CGRect]) {
        let user = anchorDisplayIDs().map { CGDisplayBounds($0) }
        let others = onlineDisplayIDs().filter { $0 != id && CGDisplayMirrorsDisplay($0) == 0 }.map { CGDisplayBounds($0) }.filter { !$0.isEmpty }
        return (user, others)
    }

    /// The user's displays agent displays are placed by: `userDisplayIDs`
    /// without other apps' virtual displays (another computer-use agent's,
    /// say, #110). Those are no more the user's than ours are, and their
    /// app moves them about: placed by one, agent displays chase it, macOS
    /// moves it to keep the layout joined up, and the two never settle.
    /// (They're still the user's everywhere else: the cursor isn't fenced
    /// off them, and windows on them are left alone.) When every display
    /// is virtual (a Mac with only DisplayLink screens, say), all of them.
    static func anchorDisplayIDs() -> [CGDirectDisplayID] {
        anchorDisplays(userDisplayIDs(), isVirtual: isVirtualDisplay)
    }

    static func anchorDisplays(_ ids: [CGDirectDisplayID], isVirtual: (CGDirectDisplayID) -> Bool) -> [CGDirectDisplayID] {
        let real = ids.filter { !isVirtual($0) }
        return real.isEmpty ? ids : real
    }

    /// A display made with macOS's virtual display API, by any app.
    static var isVirtualDisplay: (CGDirectDisplayID) -> Bool = { id in
        guard let info = coreDisplayInfo, let dict = info(id)?.takeRetainedValue() as? [String: Any] else { return false }
        return (dict["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue ?? false
    }

    private typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let coreDisplayInfo: DisplayInfo? = {
        guard let lib = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let sym = dlsym(lib, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(sym, to: DisplayInfo.self)
    }()

    /// The bottom-right corner of the rightmost of `displays` (the lowest,
    /// of those that end as far right). Not the corner of their bounding
    /// box: where no display has that corner (the one on the right is the
    /// shorter), a display put there touches none, and macOS moves it.
    /// Right of every display, so it covers none.
    static func corner(of displays: [CGRect]) -> CGPoint? {
        let real = displays.filter { !$0.isEmpty && $0.maxX.isFinite && $0.maxY.isFinite }
        guard let right = real.max(by: { ($0.maxX, $0.maxY) < ($1.maxX, $1.maxY) }) else { return nil }
        return CGPoint(x: right.maxX, y: right.maxY)
    }

    /// Whether an agent display at `rect` is fine where it is: it covers no
    /// other display, and meets the user's only at a corner (along an
    /// edge, the cursor would wander onto it). Whatever macOS did to get it
    /// there, it stays: moving it again moves the displays around it, and
    /// another app's display placed by the same rule moves back (#110).
    static func acceptable(_ rect: CGRect, user: [CGRect], others: [CGRect]) -> Bool {
        guard !rect.isEmpty else { return false }
        if others.contains(where: { overlapArea(rect, $0) > 0 }) { return false }
        return !user.contains { sharesEdge(rect, $0) }
    }

    /// The first free place for an agent display of `size`: `preferred`
    /// (its place in the staircase) if that's `acceptable`, else the
    /// nearest bottom-right corner of another display that is. Taking a
    /// free place, it pushes no other display aside: an app's display
    /// already at the staircase's corner stays there, and this one goes
    /// past it. With nothing free, `preferred` (macOS sorts it out).
    static func spot(size: CGSize, preferred: CGPoint, user: [CGRect], others: [CGRect]) -> CGPoint {
        func fits(_ p: CGPoint) -> Bool { acceptable(CGRect(origin: p, size: size), user: user, others: others) }
        if fits(preferred) { return preferred }
        let corners = (user + others).filter { !$0.isEmpty }.map { CGPoint(x: $0.maxX, y: $0.maxY) }
        func distance(_ p: CGPoint) -> CGFloat { hypot(p.x - preferred.x, p.y - preferred.y) }
        let sorted = corners.sorted { (distance($0), $0.x, $0.y) < (distance($1), $1.x, $1.y) }
        return sorted.first(where: fits) ?? preferred
    }

    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// `a` and `b` touch along an edge (not just at a corner).
    static func sharesEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        let xOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let yOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let side = (a.maxX == b.minX || a.minX == b.maxX) && yOverlap > 0
        let topOrBottom = (a.maxY == b.minY || a.minY == b.maxY) && xOverlap > 0
        return side || topOrBottom
    }

    /// The user's displays (see `anchorDisplayIDs`), as one rect.
    private func computeUserBounds() -> CGRect {
        Self.anchorDisplayIDs().reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// Re-placements a display is allowed: `limit` in any `windowMs`, then
    /// none for `pauseMs`. However the displays around it move, an agent
    /// display moves a bounded number of times (#110: an app that put its
    /// own display back each time had BCU's move about once a second).
    struct MoveBudget {
        var limit = 4
        var windowMs = 10_000.0
        var pauseMs = 30_000.0
        private(set) var moves: [Double] = []
        private(set) var pausedUntilMs = 0.0

        /// Whether a move now is allowed; if so, it's counted.
        mutating func take(nowMs: Double) -> Bool {
            if nowMs < pausedUntilMs { return false }
            moves = moves.filter { nowMs - $0 < windowMs }
            if moves.count >= limit {
                pausedUntilMs = nowMs + pauseMs
                moves = []
                return false
            }
            moves.append(nowMs)
            return true
        }

    }

    /// The 2x mode at our point size, if the display isn't in it. macOS
    /// remembers a mode per display serial, so a display first made at 1x
    /// would stay 1x.
    private func retinaModeNeeded() -> CGDisplayMode? {
        if let current = CGDisplayCopyDisplayMode(displayID), current.width == width, current.pixelWidth == width * 2 { return nil }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let retina = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) else {
            Log.info("agent display has no 2x mode at \(width)x\(height)")
            return nil
        }
        return retina
    }

    /// What to change so the agent display mirrors nothing and nothing
    /// mirrors it, as (display, what it should mirror now; 0: nothing).
    /// `mirrorOf` is what each online display mirrors (0: none). The agent
    /// display mirroring a user display stops. User displays mirroring the
    /// agent display stop too, but when there are two or more the mirroring
    /// among them is the user's: one of them (`main` if it's one, else the
    /// lowest ID) stops and becomes the source the others mirror, so only
    /// the agent display leaves the set.
    static func unmirrorPlan(agent: CGDirectDisplayID, main: CGDirectDisplayID,
                             mirrorOf: [CGDirectDisplayID: CGDirectDisplayID]) -> [(display: CGDirectDisplayID, source: CGDirectDisplayID)] {
        var plan: [(display: CGDirectDisplayID, source: CGDirectDisplayID)] = []
        if let of = mirrorOf[agent], of != 0 { plan.append((agent, 0)) }
        let mirroringAgent = mirrorOf.filter { id, of in id != agent && of == agent }.map(\.key).sorted()
        guard let source = mirroringAgent.contains(main) ? main : mirroringAgent.first else { return plan }
        plan.append((source, 0))
        for id in mirroringAgent where id != source { plan.append((id, source)) }
        return plan
    }

    /// A user display mirroring the agent display (Control Center's Screen
    /// Mirroring, a mirroring shortcut, or a mirror set macOS remembered)
    /// takes on its 1600x1000 mode: the user's screen shrinks to that, at the
    /// wrong shape on a screen that isn't 16:10 (measured on macOS 26.1: the
    /// built-in display went from 1680x1050 to 1600x1000 and stayed so while
    /// the agent display was there), and macOS fits the user's windows to it.
    /// The other way round, the agent display sits on top of the user's
    /// screen. Undo it before anything else; a mode set while mirrored is
    /// the whole mirror set's.
    private func unmirror() {
        var mirrorOf: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for id in Self.onlineDisplayIDs() { mirrorOf[id] = CGDisplayMirrorsDisplay(id) }
        let plan = Self.unmirrorPlan(agent: displayID, main: CGMainDisplayID(), mirrorOf: mirrorOf)
        guard !plan.isEmpty else { return }
        let targets = plan.map(\.display)
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for step in plan { CGConfigureDisplayMirrorOfDisplay(config, step.display, step.source) }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Self.noteChange()
        // (A failure repeated every second is logged once.)
        if err == .success || err != lastUnmirrorError {
            Log.info("agent display \(slot + 1) (\(displayID)) was mirrored (displays \(targets.map(String.init).joined(separator: ", "))); \(err == .success ? "stopped the mirroring" : "stopping it failed: \(err.rawValue)")")
        }
        lastUnmirrorError = err
    }
    private var lastUnmirrorError: CGError = .success

    /// Put the display at its place, and into `mode` if given, in one
    /// configuration: each one macOS completes rearranges every display.
    fileprivate func place(mode: CGDisplayMode? = nil) {
        unmirror()
        userBounds = computeUserBounds()
        let origin = anchor().flatMap { abs($0.x) < 1e6 && abs($0.y) < 1e6 ? $0 : nil }
        let current = CGDisplayBounds(displayID)
        if origin == nil { Log.info("agent display not placed: no user display") }
        // Placed once a user display shows up (see `reconfigured`).
        guard mode != nil || (origin != nil && origin != current.origin) else {
            bounds = current
            onChange?()
            return
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        if let mode { CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) }
        if let origin { CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y)) }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Self.noteChange()
        // (The same failure every second, while the screens sleep, is logged once.)
        if err != .success && err != lastPlaceError { Log.info("configuring the agent display failed: \(err.rawValue)") }
        lastPlaceError = err
        if mode != nil && err == .success { Log.info("agent display switched to \(width)x\(height) at 2x") }
        bounds = CGDisplayBounds(displayID)
        userBounds = computeUserBounds()
        onChange?()
    }

    private static let changeLock = NSLock()
    private static var lastChangeMs = 0.0

    /// A display is being added, removed, moved or switched to another mode.
    static func noteChange() {
        changeLock.lock(); lastChangeMs = nowMs(); changeLock.unlock()
    }

    /// Wait until the displays have been as they are for `quietMs` (`capMs`
    /// at most), and return how long that took. An app hears of a new
    /// display a moment after it's added, and until then a window it's asked
    /// to build there goes to the main display instead (measured: a browser
    /// window asked for on a display 1.7 s old, with two more being added,
    /// sat in the corner of the user's screen for 1.5 s, and moving it failed
    /// until the displays were done). Not on the main thread: macOS reports
    /// display changes there.
    @discardableResult
    public static func awaitSettled(quietMs: Double = 700, capMs: Double = 8000) -> Double {
        let start = nowMs()
        while true {
            changeLock.lock(); let last = lastChangeMs; changeLock.unlock()
            let now = nowMs()
            if now - last >= quietMs || now - start >= capMs { return now - start }
            sleepMs(max(5, min(50, quietMs - (now - last))))
        }
    }

    /// Main thread: macOS finished rearranging the displays.
    fileprivate static func displaysChanged() {
        registryLock.lock(); fencedCache.atMs = -1; strayCache.atMs = -1; registryLock.unlock()
        for d in running { d.reconfigured() }
    }

    /// Main thread, every second. A display macOS wouldn't place (the
    /// screens were asleep, or gone) stays where macOS put it, which can be
    /// on top of where the user's display comes back: put it right as soon
    /// as that works. And with no user display left at all, spares go.
    public static func tend() {
        if userDisplayIDs().isEmpty {
            reapSpares(all: true)
            return
        }
        reapSpares()
        for d in running { d.reconfigured() }
        registryLock.lock()
        let kept = spares.map { CGDisplayBounds($0.id) }
        registryLock.unlock()
        WindowManager.rescue(fromSpares: kept)
        // A stray only once it's been one a while: not one of ours caught
        // in the moment between coming online and being registered.
        let now = nowMs()
        let strays = strayIDs
        strayFirstSeen = strayFirstSeen.filter { strays.contains($0.key) }
        for id in strays where strayFirstSeen[id] == nil { strayFirstSeen[id] = now }
        WindowManager.rescue(fromStrays: strays.filter { now - (strayFirstSeen[$0] ?? now) >= 5000 }.map { CGDisplayBounds($0) })
    }

    /// When each stray display was first seen (main thread).
    private static var strayFirstSeen: [CGDirectDisplayID: Double] = [:]

    /// No user display to sit beside the last time this looked.
    private var unplaced = false
    /// Where macOS put the display when it was asked for `wanted` and said
    /// yes: it moves a display that touches no other one. Asking again
    /// gets the same answer, and each ask rearranges every display.
    private var adjusted: (wanted: CGPoint, got: CGPoint)?
    private var lastPlaceError: CGError = .success
    /// How often it may still move (see `MoveBudget`).
    private var budget = MoveBudget()
    /// Out of moves for now, and that's been logged.
    private var holding = false

    /// Main thread: the displays changed, or a second went by (`tend`).
    /// The display stays where it is while that's `acceptable`, however
    /// the others moved: it goes back to its place in the staircase only
    /// when the user's own displays change, and elsewhere only when macOS
    /// left it on top of another display or along the user's.
    fileprivate func reconfigured() {
        // A display still coming online is placed when it arrives.
        guard isRunning, !bounds.isEmpty else { return }
        let user = computeUserBounds()
        let b = CGDisplayBounds(displayID)
        guard let wanted = anchor() else {
            if !unplaced {
                unplaced = true
                Log.info("agent display \(slot + 1) has no user display to sit beside; it stays at \(b.short) until one is back")
            }
            bounds = b
            return
        }
        let accepted = adjusted.map { $0.wanted == wanted && $0.got == b.origin } ?? false
        // Mirrored since it was placed (see `unmirror`).
        let mirrored = CGDisplayIsInMirrorSet(displayID) != 0
        let layout = Self.layout(excluding: displayID)
        let move = Self.needsPlacing(b, wanted: wanted, userChanged: user != userBounds, user: layout.user, others: layout.others)
        guard unplaced || mirrored || (move && !accepted) else {
            userBounds = user
            if b != bounds {
                bounds = b
                onChange?()
            }
            return
        }
        if !mirrored && !budget.take(nowMs: nowMs()) {
            if !holding {
                holding = true
                Log.info("agent display \(slot + 1) moved \(budget.limit) times in \(Int(budget.windowMs / 1000)) s; it stays at \(b.short) for \(Int(budget.pauseMs / 1000)) s (displays: \(Self.layoutSummary))")
            }
            if b != bounds {
                bounds = b
                onChange?()
            }
            return
        }
        holding = false
        let was = unplaced
        unplaced = false
        place()
        if bounds.origin == wanted {
            adjusted = nil
            Log.info("agent display \(slot + 1) re-placed at \(bounds.short)")
        } else if lastPlaceError == .success {
            if adjusted.map({ $0.wanted != wanted || $0.got != bounds.origin }) ?? true {
                Log.info("agent display \(slot + 1) asked for \(Int(wanted.x)),\(Int(wanted.y)); macOS put it at \(bounds.short)")
            }
            adjusted = (wanted, bounds.origin)
        } else if !was { unplaced = true }
    }

    /// Whether an agent display at `rect` should be put somewhere else:
    /// back at `wanted` (its place in the staircase) when the user's own
    /// displays changed, or anywhere better when it isn't `acceptable`.
    /// Not because another display moved, or because it isn't at `wanted`:
    /// a display that moves for that moves the others, and one that's
    /// placed the same way (after the last display that isn't its app's)
    /// moves again in turn, forever (#110).
    static func needsPlacing(_ rect: CGRect, wanted: CGPoint, userChanged: Bool, user: [CGRect], others: [CGRect]) -> Bool {
        if userChanged && rect.origin != wanted { return true }
        return !acceptable(rect, user: user, others: others)
    }

    /// Every online display and where it is, for the log.
    static var layoutSummary: String {
        onlineDisplayIDs().map { id in
            let b = CGDisplayBounds(id)
            return "\(id)[\(String(CGDisplayVendorNumber(id), radix: 16))]@\(Int(b.minX)),\(Int(b.minY))"
        }.joined(separator: " ")
    }

    /// True when most of `rect` is on the agent display.
    public func holds(_ rect: CGRect) -> Bool {
        guard isRunning, !rect.isEmpty else { return false }
        let inter = rect.intersection(bounds)
        return !inter.isNull && inter.width * inter.height >= 0.5 * rect.width * rect.height
    }

    /// True when any part of `rect` is visible on one of the user's displays.
    public func touchesUser(_ rect: CGRect) -> Bool {
        userDisplayIDs().contains { CGDisplayBounds($0).intersects(rect) }
    }

    /// Where a window of `size` should go on the agent display, cascading by `slot`.
    public func slotFrame(size: CGSize, slot: Int) -> CGRect {
        let inset: CGFloat = 24
        let maxW = bounds.width - inset * 2
        let maxH = bounds.height - inset * 2 - 30
        let w = min(max(size.width, 400), maxW)
        let h = min(max(size.height, 300), maxH)
        let step = CGFloat(slot % 6) * 28
        let x = bounds.minX + inset + min(step, bounds.width - w - inset * 2)
        let y = bounds.minY + inset + 30 + min(step, bounds.height - h - inset * 2 - 30)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private func reconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    AgentDisplay.noteChange()
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async { AgentDisplay.displaysChanged() }
}
