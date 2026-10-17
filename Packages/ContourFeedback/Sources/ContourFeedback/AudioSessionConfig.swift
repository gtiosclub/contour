//
//  AudioSessionConfig.swift
//  ContourFeedback — Experience / Audio & Speech
//
//  The one place Contour touches AVAudioSession's category. Ported from #32.
//
//  ContourApp calls `configure()` once at launch. After that, nothing else sets a
//  category or activates the session: the directional tone, the earcons and the
//  SpeechQueue all share this one session, and they learn about interruptions
//  (a phone call, Siri) and route changes (headphones in or out) by listening to
//  `events()` — not by each observing the system notifications themselves.
//
//  CATEGORY
//  `.playAndRecord`, because voice target selection needs the microphone while
//  the tone and speech play. `.defaultToSpeaker` so the tone comes out of the
//  loudspeaker rather than the earpiece when nothing is plugged in, and
//  `.allowBluetoothA2DP` so stereo Bluetooth headphones keep the left/right pan.
//  Mode stays `.default`: `.spokenAudio` is a playback-only mode, and
//  `.voiceChat` turns on echo-cancelling voice processing that flattens the
//  tone and collapses it to mono.
//
//  On macOS (the Harness) there is no AVAudioSession: `configure()` does nothing
//  and `events()` finishes immediately.
//

import Foundation

#if os(iOS)
import AVFAudio
import os

/// The one shared audio-session owner for Contour.
///
/// Configure this once at app launch. Tone, speech, and microphone features consume
/// its events but never set an AVAudioSession category themselves.
@MainActor
public enum AudioSessionConfig {

    /// Something happened to the shared session that a player may need to
    /// recover from.
    public enum Event: Sendable, Equatable {
        /// The system took the session (a call, an alarm, Siri). Players are
        /// paused by the system.
        case interruptionBegan
        /// The interruption is over. Restart if `shouldResume` and you still
        /// want to play.
        case interruptionEnded(shouldResume: Bool)
        /// Headphones in or out, a Bluetooth device connected, and so on. An
        /// AVAudioEngine stops itself on most of these.
        case routeChanged(reasonRawValue: UInt)
    }

    private static var isConfigured = false
    private static var observers: [NSObjectProtocol] = []
    private static var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private static let logger = Logger(subsystem: "com.gtiosclub.contour", category: "audio-session")

    /// Configures play-and-record audio and starts rebroadcasting system audio
    /// events. Safe to call more than once; only the first call does anything.
    public static func configure() throws {
        guard !isConfigured else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )

        // Activation is synchronous and can take a while. Keep it off the main
        // actor so it does not hold up launch.
        Task.detached {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                reportActivationFailure(error)
            }
        }

        observers = [
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { notification in
                if let event = interruptionEvent(from: notification) {
                    Task { @MainActor in broadcast(event) }
                }
            },
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { notification in
                let event = routeChangeEvent(from: notification)
                Task { @MainActor in broadcast(event) }
            },
        ]
        isConfigured = true
    }

    /// A broadcast stream of interruptions and route changes for audio engines.
    ///
    /// Every call returns a new stream; every stream gets every event. It is
    /// fine to subscribe before `configure()` — events start flowing once it runs.
    public static func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in continuations[id] = nil }
            }
        }
    }

    nonisolated private static func reportActivationFailure(_ error: any Error) {
        let message = String(describing: error)
        Task { @MainActor in
            logger.error("could not activate the audio session: \(message, privacy: .public)")
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

/// The macOS stand-in, so the Harness compiles the same calls. AVAudioSession is
/// iOS-only; a Mac's audio needs no category and has no interruptions to report.
@MainActor
public enum AudioSessionConfig {

    /// Same cases as on iOS. Never emitted on macOS.
    public enum Event: Sendable, Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reasonRawValue: UInt)
    }

    /// Does nothing on macOS.
    public static func configure() throws {}

    /// A stream that finishes immediately on macOS.
    public static func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
#endif
