import AppKit
import CPrivate

/// Open and save panels and the keyboard. Nothing is held for them yet.
public enum PanelFocus {
    static func applies(osMajor: Int) -> Bool { false }
    static let onThisMac = applies(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    static let maxHoldMs = FocusGuard.maxHoldMs
    static let settleMs = 20.0
    static let afterStepMs = 250.0

    static func holds(choosing: Bool, keyFocus: pid_t, front: pid_t, isHelper: Bool, userPanelOpen: Bool) -> Bool {
        false
    }

    static func choosing(steps: Int, lastEndMs: Double, nowMs: Double) -> Bool {
        false
    }

    struct Hold {
        let helper: pid_t
        let sinceMs: Double

        init(helper: pid_t, sinceMs: Double) {
            self.helper = helper
            self.sinceMs = sinceMs
        }

        enum End: Equatable {
            case back
            case stepOver
            case expired
        }

        mutating func sample(helperHasKey: Bool, choosing: Bool, nowMs: Double) -> End? {
            nil
        }
    }
}
