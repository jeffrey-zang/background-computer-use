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
    /// Input a session sent: when, to which processes (an open or save
    /// panel's service as well as the app), the key if it was one, and the
    /// call it was part of. For a step that waited its turn in the app (the
    /// user typing, another agent's step), only the moment it sent counts.
    public struct Step {
        public let start: Date
        /// `.distantFuture` while the input is still being sent.
        public var end: Date
        public let key: String?
        public let pids: Set<pid_t>
        public let owner: String
        /// When the call it was part of began.
        public let call: Date
        public init(start: Date, end: Date, key: String?, pids: Set<pid_t>, owner: String, call: Date) {
            self.start = start; self.end = end; self.key = key; self.pids = pids; self.owner = owner; self.call = call
        }
    }

    private var steps: [Step] = []

    private var nextStepID = 1
    private var open: [Int: Int] = [:]

    /// Input about to be sent, listed before it is (open-ended), so another
    /// session looking at a beep meanwhile sees it; `finish` closes it.
    public func begin(_ step: Step) -> Int {
        lock.lock(); defer { lock.unlock() }
        var s = step
        s.end = .distantFuture
        steps.append(s)
        let id = nextStepID
        nextStepID += 1
        open[id] = steps.count - 1
        return id
    }

    public func finish(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let i = open.removeValue(forKey: id), i < steps.count else { return }
        steps[i].end = Date()
        prune()
    }

    /// Under `lock`. Only while nothing is being sent: `open` holds indexes.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-60)
        if open.isEmpty, steps.count > 200 || steps.first.map({ $0.end < cutoff }) == true {
            steps = steps.filter { $0.end >= cutoff }.suffix(200)
        }
        if assigned.count > 200 { assigned = assigned.filter { $0.key > nextSeq - 200 } }
    }

    /// Which input each beep was put down to, once some session has: later
    /// input can't take it over (and report it a second time).
    private var assigned: [Int: Step] = [:]

    /// `agents` over the steps listed now, keeping each beep with the input
    /// it was first put down to.
    public func attribute(_ beeps: [Beep], owner: String, tail: TimeInterval = 1.0) -> [(beep: Beep, step: Step)] {
        lock.lock(); defer { lock.unlock() }
        var out: [(beep: Beep, step: Step)] = []
        for b in beeps {
            let step: Step
            if let s = assigned[b.seq] {
                step = s
            } else if let s = Self.agents([b], steps: steps, owner: nil, tail: tail).first?.step {
                assigned[b.seq] = s
                step = s
            } else { continue }
            if step.owner == owner { out.append((b, step)) }
        }
        return out
    }

    /// Every session's input goes here, so a beep is put down to one step.
    public func record(_ step: Step) {
        lock.lock(); defer { lock.unlock() }
        steps.append(step)
        prune()
    }

    public var recentSteps: [Step] { lock.lock(); defer { lock.unlock() }; return steps }

    /// Which of `beeps` `owner`'s input set off, each with its step. A beep
    /// goes to the latest input to its process (any session's) that it
    /// came during or up to `tail` after (the app beeps once it has handled
    /// the key: 0.2 s after it in TextEdit), and counts only if that input
    /// was `owner`'s. A beep with no such input is the user's own.
    /// `owner` nil: whoever's it is.
    public static func agents(_ beeps: [Beep], steps: [Step], owner: String?, tail: TimeInterval = 1.0) -> [(beep: Beep, step: Step)] {
        beeps.compactMap { b in
            // Input that began after the request can't have caused it (10 ms
            // for the log's and this process's clocks).
            let step = steps.filter { $0.pids.contains(b.pid) && $0.start <= b.at.addingTimeInterval(0.01) && b.at <= $0.end.addingTimeInterval(tail) }
                .max { $0.start < $1.start }
            guard let step, owner == nil || step.owner == owner else { return nil }
            return (b, step)
        }
    }

    /// The step result's note for the beeps it set off (and any from the
    /// step before, logged after it returned).
    /// `current`: when the call this note goes with began; beeps from an
    /// earlier call (logged after it returned) are put down to its key.
    public static func note(_ found: [(beep: Beep, step: Step)], current: Date) -> String? {
        guard !found.isEmpty else { return nil }
        let now = found.filter { $0.step.call == current }
        let earlier = found.filter { $0.step.call != current }
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
