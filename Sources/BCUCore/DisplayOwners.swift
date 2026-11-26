import CoreGraphics
import Darwin
import Foundation

/// Which engine made each BCU display, so an engine can tell another live
/// engine's display (a second copy of the app, a test engine beside the
/// installed one) from one a crashed copy left. Both look the same to macOS
/// (see `AgentDisplay.isBCUDisplay`), and moving the windows off a live
/// one starts a fight with that engine's guard, which moves them straight
/// back (#95). Engines can each have their own `BCU_HOME`, so the records
/// live in the user's temp directory, which all of this user's engines
/// share: one file per display, named by its ID, holding the owner's
/// process ID and start time (a reused process ID doesn't count).
enum DisplayOwners {
    /// Where the records go. Tests point it elsewhere.
    static var directory: URL = {
        // Not $TMPDIR: an engine started from a sandboxed shell can have its
        // own. This one is the same for every process of the user.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let base = n > 0 && n <= buf.count ? String(cString: buf) : NSTemporaryDirectory()
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("bcu-display-owners", isDirectory: true)
    }()

    struct Owner: Equatable {
        let pid: pid_t
        let start: UInt64
    }

    /// When `pid` started (microseconds since 1970), nil if it isn't running.
    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static let me: Owner? = startTime(of: getpid()).map { Owner(pid: getpid(), start: $0) }

    private static func file(_ id: CGDirectDisplayID) -> URL {
        directory.appendingPathComponent(String(id))
    }

    /// This process made display `id`.
    static func claim(_ id: CGDirectDisplayID, as owner: Owner? = me) {
        guard id != 0, let owner else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(owner.pid) \(owner.start)\n".utf8).write(to: file(id), options: .atomic)
    }

    /// Display `id` is gone. Only our own record goes: another engine may
    /// have been given the same ID since.
    static func release(_ id: CGDirectDisplayID, as owner: Owner? = me) {
        guard id != 0, let owner, self.owner(of: id) == owner else { return }
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Who recorded display `id`, alive or not.
    static func owner(of id: CGDirectDisplayID) -> Owner? {
        guard let text = try? String(contentsOf: file(id), encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = pid_t(parts[0]), let start = UInt64(parts[1]) else { return nil }
        return Owner(pid: pid, start: start)
    }

    /// The live engine that owns display `id`, if one does. Nil: nobody
    /// recorded it (a crashed copy from before these records, or one that
    /// never got to write it) or its owner has exited.
    static func liveOwner(of id: CGDirectDisplayID) -> Owner? {
        guard let o = owner(of: id), o != me, startTime(of: o.pid) == o.start else { return nil }
        return o
    }
}
