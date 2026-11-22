import AppKit

/// A `drag` that starts macOS's drag and drop: the app under it writes the
/// drag pasteboard as the drag begins. Before macOS 27 that drag and drop
/// follows the user's real pointer, not the events posted to the agent's
/// window, so it never drops there. Measured with Finder on 15.8 and 26.7:
/// the drag pasteboard changed, Finder logged "Cannot start a new drag",
/// and the file stayed put. 27.0 and 27.3 drop it.
///
/// Gated by version because nothing outside the app tells whether a drop
/// happened: on 27 the drag pasteboard changes the same way.
public enum SystemDrag {
    static func followsRealPointer(osMajor: Int) -> Bool { osMajor < 27 }
    static let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    static let onThisMac = followsRealPointer(osMajor: osMajor)

    /// Whether a drag that took the drag pasteboard's change count from
    /// `before` to `after` dropped nothing.
    static func dropLost(before: Int, after: Int, osMajor: Int) -> Bool {
        after != before && followsRealPointer(osMajor: osMajor)
    }

    static var changeCount: Int { NSPasteboard(name: .drag).changeCount }

    static let refusal = "Nothing was dropped. The drag started a macOS drag and drop, and before macOS 27 that follows the user's real pointer, so it can't drop in your window. Do it another way: `choose_file` for an upload, Edit > Copy then Edit > Move Items Here in Finder to move files, or the app's own menus."
}
