import Foundation

/// Alert sounds the agent's input sets off. An app that refuses a key or a
/// shortcut (Escape with nothing to dismiss, a disabled menu item's
/// shortcut) calls `NSBeep`, which `systemsoundserverd` plays, not the app:
/// so the beep isn't the app's audio, isn't caught by `SessionAudio`'s tap
/// or `capture_audio`, and plays on the user's speakers even when every
/// window of the app is on an agent display.
///
/// `systemsoundserverd` logs every request with the app that made it, so a
/// `log stream` of those lines (which needs no permission, only an admin
/// user, and works while the Mac is muted) tells which app beeped and when.
/// Each step's result then says its app beeped: the key most likely did
/// nothing, which is also worth knowing for the agent.
public final class BeepWatch {
    public static let shared = BeepWatch()

    public struct Beep: Equatable {
        /// When `systemsoundserverd` got the request.
        public let at: Date
        public let pid: pid_t
        public let app: String
        /// 4096 is the user's alert sound (`NSBeep`); others are an app's
        /// own system sounds.
        public let action: Int
        /// Order of arrival, to report each once.
        public let seq: Int
    }

    /// The user's alert sound, `kSystemSoundID_UserPreferredAlert`.
    public static let alertAction = 4096

    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var recent: [Beep] = []
    private var nextSeq = 1
    private var startedAt: Date?
    private var lastStartMs = -Double.infinity
    /// `log` isn't there, or won't stream (not an admin user).
    private var unavailable = false

    public static let predicate = #"process == "systemsoundserverd" AND eventMessage CONTAINS "Incoming Request""#

    /// Start watching if it isn't already (and wasn't refused). Cheap to call
    /// every second.
    public func ensureRunning() {
        lock.lock(); defer { lock.unlock() }
        guard !unavailable, process?.isRunning != true else { return }
        // A stream that died is started again, but not more than every 30 s.
        guard nowMs() - lastStartMs > 30_000 else { return }
        lastStartMs = nowMs()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--level", "default", "--predicate", Self.predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.take(data)
        }
        p.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            // Gone at once, unasked: `log` refuses to stream for this user.
            if self.process === p, let s = self.startedAt, Date().timeIntervalSince(s) < 2 {
                self.unavailable = true
                Log.info("beeps: log stream exited (\(p.terminationStatus)); app beeps won't be reported")
            }
            // Not a replacement started since this one was stopped.
            if self.process === p { self.process = nil }
            self.lock.unlock()
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
        } catch {
            unavailable = true
            Log.info("beeps: can't run log stream: \(error)")
        }
    }

    public func stop() {
        lock.lock(); let p = process; process = nil; lastStartMs = -Double.infinity; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Whether beeps are being watched for now.
    public var watching: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    private func take(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let b = Self.parse(line: Data(line), seq: nextSeq) else { continue }
            nextSeq += 1
            recent.append(b)
        }
        // A minute is plenty: steps take seconds at most.
        let cutoff = Date().addingTimeInterval(-60)
        if recent.count > 64 || recent.first.map({ $0.at < cutoff }) == true {
            recent = recent.filter { $0.at >= cutoff }.suffix(64)
        }
    }

    /// The beeps after `seq` (each reported once).
    public func beeps(after seq: Int) -> [Beep] {
        lock.lock(); defer { lock.unlock() }
        return recent.filter { $0.seq > seq }
    }

    /// The last beep's sequence number so far.
    public var lastSeq: Int { lock.lock(); defer { lock.unlock() }; return nextSeq - 1 }

    /// Test hook: as if `systemsoundserverd` had logged this.
    func inject(_ b: (at: Date, pid: pid_t, app: String, action: Int)) {
        lock.lock(); defer { lock.unlock() }
        recent.append(Beep(at: b.at, pid: b.pid, app: b.app, action: b.action, seq: nextSeq))
        nextSeq += 1
    }

    // MARK: Parsing

    /// One `log stream --style ndjson` line, if it's a sound request.
    static func parse(line: Data, seq: Int) -> Beep? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["eventMessage"] as? String,
              let (action, pid, app) = parse(message: message) else { return nil }
        let at = (obj["timestamp"] as? String).flatMap(parse(timestamp:)) ?? Date()
        return Beep(at: at, pid: pid, app: app, action: action, seq: seq)
    }

    /// "-> Incoming Request : actionID 4096, inClientPID 62902(TextEdit), inBehavior 1, …"
    static func parse(message: String) -> (action: Int, pid: pid_t, app: String)? {
        guard let r = message.range(of: #"Incoming Request : actionID (\d+), inClientPID (\d+)\(([^)]*)\)"#, options: .regularExpression) else { return nil }
        let s = String(message[r])
        let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2, let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
        return (nums[0], pid_t(nums[1]), String(s[s.index(after: open)..<close]))
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    /// "2026-11-26 02:55:21.804543-0800"
    static func parse(timestamp: String) -> Date? {
        stampFormat.date(from: timestamp)
    }

    // MARK: Whose beep

    /// One of the agent's input steps: when it ran, and the key it
    /// pressed (for the note), if it pressed one.
    public struct Step {
        public let start: Date
        public var end: Date
        public let key: String?
        public init(start: Date, end: Date, key: String?) { self.start = start; self.end = end; self.key = key }
    }

    /// Which of `beeps` the agent's steps set off, each with the step: from
    /// an app it acted on, at a moment one of its input steps ran, or
    /// shortly after one (the app beeps once it has handled the key: 0.2 s
    /// after it in TextEdit). A beep at any other time is the user's own.
    public static func agents(_ beeps: [Beep], pids: Set<pid_t>, steps: [Step], tail: TimeInterval = 1.0) -> [(beep: Beep, step: Step)] {
        beeps.compactMap { b in
            guard pids.contains(b.pid) else { return nil }
            // The latest step it can be from.
            let step = steps.last { b.at >= $0.start.addingTimeInterval(-0.05) && b.at <= $0.end.addingTimeInterval(tail) }
            return step.map { (b, $0) }
        }
    }

    /// The step result's note for the beeps it set off (and any from the
    /// step before, logged after it returned).
    /// `current`: the step this note goes with; beeps from an earlier step
    /// (logged after it returned) are put down to that step's key.
    public static func note(_ found: [(beep: Beep, step: Step)], current: Date) -> String? {
        guard !found.isEmpty else { return nil }
        let now = found.filter { $0.step.start == current }
        let earlier = found.filter { $0.step.start != current }
        var parts: [String] = []
        if !now.isEmpty { parts.append(note(now.map(\.beep), key: now[0].step.key)!) }
        if !earlier.isEmpty {
            let key = earlier.last!.step.key
            parts.append("After your previous step: " + note(earlier.map(\.beep), key: key, earlier: true)!)
        }
        return parts.joined(separator: " ")
    }

    public static func note(_ beeps: [Beep], key: String?, earlier: Bool = false) -> String? {
        guard !beeps.isEmpty else { return nil }
        var byApp: [String: (alerts: Int, other: Int)] = [:]
        var order: [String] = []
        for b in beeps {
            if byApp[b.app] == nil { order.append(b.app); byApp[b.app] = (0, 0) }
            if b.action == alertAction { byApp[b.app]!.alerts += 1 } else { byApp[b.app]!.other += 1 }
        }
        let parts = order.map { app -> String in
            let c = byApp[app]!
            if c.alerts > 0 {
                let times = c.alerts == 1 ? "" : " \(c.alerts) times"
                return "\(app) beeped\(times) (its alert sound, which plays on the user's speakers)"
            }
            return "\(app) played a system sound on the user's speakers"
        }
        let what = key.map { "\($0) most likely did nothing there" } ?? (earlier ? "that step's input most likely did nothing there" : "the input most likely did nothing there")
        let alerts = beeps.contains { $0.action == alertAction }
        return parts.joined(separator: "; ") + "." + (alerts ? " An app beeps when it refuses input: \(what). Check the window before going on, and don't send keys that would only beep." : "")
    }
}
