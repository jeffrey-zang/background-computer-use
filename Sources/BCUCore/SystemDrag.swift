import AppKit

/// A `drag` that starts macOS's drag and drop: the app under it writes the
/// drag pasteboard as the drag begins.
public enum SystemDrag {
    /// Whether a drag that took the drag pasteboard's change count from
    /// `before` to `after` dropped nothing.
    static func dropLost(before: Int, after: Int, osMajor: Int) -> Bool { false }
}
