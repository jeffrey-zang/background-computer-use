/// Whether setup shows at launch.
public enum SetupGate {
    /// `done`: setup was finished once. `reopened`: setup quit the app to
    /// pick up Screen Recording and should carry on. `ready` (asked only
    /// when needed): the permissions are on and an agent is connected.
    public static func shouldShow(done: Bool, reopened: Bool, ready: () -> Bool) -> Bool {
        // Before `done`: setup run again from the ⋯ menu can quit and reopen too.
        if reopened { return true }
        if done { return false }
        return !ready()
    }
}

/// System Audio Recording as setup shows it, from TCC's preflight answer
/// (`BCUAudioCapturePreflight`). Only "not asked" holds up for good:
/// allowed in System Settings after a denial can still read as denied.
public enum AudioAccess: Equatable {
    case allowed, denied, notAsked
    /// No preflight on this Mac: setup has nothing to ask.
    case unavailable

    public init(preflight: Int32) {
        switch preflight {
        case 0: self = .allowed
        case 2: self = .notAsked
        case -1: self = .unavailable
        default: self = .denied
        }
    }

    /// Setup has a step for it until it's allowed.
    public var setupShows: Bool { self == .notAsked || self == .denied }
}
