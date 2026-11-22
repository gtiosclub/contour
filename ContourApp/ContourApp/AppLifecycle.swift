import AVFoundation
import SwiftUI

/// What the camera screen does when the app is covered, leaves, or loses its audio.
/// Kept apart from the views so the rules can be tested without a phone.
nonisolated enum AppLifecycle {

    /// Whether the camera, the current request and a plan keep running in `phase`.
    ///
    /// Only the background stops them. Inactive is Control Center, Notification
    /// Center, Siri or a permission alert over the app, and it passes in a moment.
    /// Stopping there ended the plan and lost ARKit's calibration, and the first
    /// microphone alert cancelled the request that asked for it. Guidance goes quiet
    /// on its own while the app isn't active, and the system interrupts the camera or
    /// the audio itself if it needs them.
    static func runs(in phase: ScenePhase, wasRunning: Bool) -> Bool {
        switch phase {
        case .active: true
        case .background: false
        default: wasRunning
        }
    }

    /// Whether an audio interruption notice means the system just took the audio,
    /// like a call or Siri. That ends the current request. The notice that it's over
    /// changes nothing, and neither do route changes like AirPods or a mirroring
    /// cable coming or going: the sound just moves to wherever the system sends it.
    static func audioWasTaken(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let type = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return false }
        return AVAudioSession.InterruptionType(rawValue: type) == .began
    }
}
