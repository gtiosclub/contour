import AVFAudio
import Foundation

/// The one shared audio-session owner for Contour.
///
/// Configure this once at app launch. Tone, speech, and microphone features consume
/// its events but never set an AVAudioSession category themselves.
@MainActor
public enum AudioSessionConfig {
    public enum Event: Sendable, Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reasonRawValue: UInt)
    }

    private static var isConfigured = false
    private static var observers: [NSObjectProtocol] = []
    private static var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    /// Configures play-and-record audio and starts rebroadcasting system audio events.
    public static func configure() throws {
        guard !isConfigured else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        try session.setActive(true)

        observers = [
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { notification in
                handleInterruption(notification)
            },
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { notification in
                handleRouteChange(notification)
            }
        ]
        isConfigured = true
    }

    /// A broadcast stream of interruptions and route changes for audio engines.
    public static func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    continuations[id] = nil
                }
            }
        }
    }

    private static func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            broadcast(.interruptionBegan)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            broadcast(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }

    private static func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        broadcast(.routeChanged(reasonRawValue: rawReason))
    }

    private static func broadcast(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
