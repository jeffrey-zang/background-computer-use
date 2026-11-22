import Foundation
import CPrivate

extension AudioAccess {
    /// This app's System Audio Recording now. capture_audio needs macOS 14.2.
    public static var current: AudioAccess {
        guard #available(macOS 14.2, *) else { return .unavailable }
        return AudioAccess(preflight: BCUAudioCapturePreflight())
    }

    /// Ask for it: macOS's prompt comes up over the key window. `done` runs
    /// on the main queue once the user has answered.
    public static func request(_ done: @escaping () -> Void) {
        BCUAudioCaptureRequestThen { _ in DispatchQueue.main.async(execute: done) }
    }
}
