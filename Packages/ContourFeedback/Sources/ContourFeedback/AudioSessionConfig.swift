import Foundation

#if os(iOS)
import AVFAudio

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

        if #available(iOS 27, *) {
            session.activate { success, error in
                guard !success else { return }
                reportActivationFailure(error)
            }
        } else {
            // iOS 26 does not expose asynchronous activation. Keep the synchronous
            // API off the main actor to avoid blocking launch-time UI responsiveness.
            Task.detached {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    reportActivationFailure(error)
                }
            }
        }

        observers = [
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { notification in
                if let event = interruptionEvent(from: notification) {
                    Task { @MainActor in
                        broadcast(event)
                    }
                }
            },
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { notification in
                let event = routeChangeEvent(from: notification)
                Task { @MainActor in
                    broadcast(event)
                }
            }
        ]
        isConfigured = true
    }

    nonisolated private static func reportActivationFailure(_ error: (any Error)?) {
        let message = error.map(String.init(describing:)) ?? "Unknown activation failure"
        Task { @MainActor in
            assertionFailure("Unable to activate Contour audio session: \(message)")
        }
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

    nonisolated private static func interruptionEvent(from notification: Notification) -> Event? {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return nil
        }

        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    nonisolated private static func routeChangeEvent(from notification: Notification) -> Event {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        return .routeChanged(reasonRawValue: rawReason)
    }

    private static func broadcast(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}

#else

/// Compatibility surface for the macOS Harness. AVAudioSession is iOS-only.
@MainActor
public enum AudioSessionConfig {
    public enum Event: Sendable, Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reasonRawValue: UInt)
    }

    public static func configure() throws {}

    public static func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
#endif
