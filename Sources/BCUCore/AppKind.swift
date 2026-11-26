import AppKit

/// What an app is built on, where that changes how input reaches it.
public enum AppKind {
    private static let lock = NSLock()
    private static var chromiumByPid: [pid_t: Bool] = [:]

    /// Built on Chromium: a browser (Chrome, Edge, Brave, Helium), an
    /// Electron app or one embedding CEF. They bundle their engine as
    /// "<Name> Framework.framework" ("Google Chrome Framework",
    /// "Electron Framework", "Chromium Embedded Framework"). Cached per
    /// process; false when the app can't be found.
    public static func isChromium(pid: pid_t) -> Bool {
        lock.lock()
        if let known = chromiumByPid[pid] { lock.unlock(); return known }
        lock.unlock()
        let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
        let result = url.map(isChromium(bundle:)) ?? false
        lock.lock(); chromiumByPid[pid] = result; lock.unlock()
        return result
    }

    public static func isChromium(bundle: URL) -> Bool {
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("Contents/Frameworks").path)) ?? []
        return isChromium(frameworks: frameworks)
    }

    static func isChromium(frameworks: [String]) -> Bool {
        frameworks.contains { $0.hasSuffix(" Framework.framework") }
    }

    /// Safari, or Safari Technology Preview: WebKit browsers whose address
    /// field takes a URL through accessibility (see `Engine.navigate`).
    public static let safariBundleIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    public static func isSafari(bundleID: String?) -> Bool {
        bundleID.map(safariBundleIDs.contains) ?? false
    }
}
