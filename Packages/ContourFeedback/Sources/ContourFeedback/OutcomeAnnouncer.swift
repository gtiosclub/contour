//
//  OutcomeAnnouncer.swift
//  ContourFeedback — Experience / Outcome Signals & Harness
//
//  Weeks 2–3 deliverable: "Define success and lost-tracking feedback with Design."
//
//  The four terminal signals. This is a JOINT deliverable — the timeline puts
//  the state-by-state feel spec on Design (Kaylee), agreed with you. Go and get
//  it in Week 2 rather than waiting for it, then encode the agreement here.
//
//  ⚠️ notFound AND lowConfidence MUST NOT FEEL THE SAME.
//  "There is no defrost button on this microwave" and "I think I see one but I
//  would be guessing" send the user to completely different next actions: one
//  means give up on that control, the other means re-aim and try again. If a
//  blindfolded tester cannot tell them apart, the design is wrong.
//
//  FIRST PASS, PENDING THE FEEL SPEC
//  The signatures below are a starting point for the MVP, not Design's answer:
//    arrived        three strong, sharp taps close together
//    lostTracking   three taps fading out
//    notFound       two heavy, dull taps far apart
//    lowConfidence  four light, quick taps, a flutter
//  The utterances are what to say once SpeechQueue lands; nothing speaks yet.
//

import ContourCore
import Foundation

/// How one outcome should be presented, agreed with Design.
///
/// Framework-free so the Harness can log it on a Mac and tests can assert on it.
public struct OutcomePresentation: Hashable, Sendable {

    /// What is spoken, if anything. `nil` means non-speech only.
    ///
    /// This is *what* to say. Actually saying it — queueing, interrupting,
    /// ducking — belongs to `SpeechQueue` in the Audio & Speech lane.
    public var utterance: String?

    /// The haptic signature for this outcome.
    public var haptics: [HapticEvent]

    /// The earcon for this outcome, if any.
    public var audio: AudioCue?

    /// Whether this interrupts whatever is currently playing.
    ///
    /// `arrived` almost certainly should. A continuous proximity pattern running
    /// underneath a success chime reads as "keep going".
    public var interrupts: Bool

    public init(
        utterance: String?,
        haptics: [HapticEvent],
        audio: AudioCue?,
        interrupts: Bool
    ) {
        self.utterance = utterance
        self.haptics = haptics
        self.audio = audio
        self.interrupts = interrupts
    }
}

/// Presents the four terminal signals.
public struct OutcomeAnnouncer: Sendable {

    private let player: HapticPlayer

    public init() {
        self.init(player: HapticPlayer())
    }

    /// Shares a player with `ProximityHaptics`, so both use one haptic engine.
    init(player: HapticPlayer) {
        self.player = player
    }

    /// How `outcome` should be presented.
    ///
    /// Pure and synchronous on purpose — this is the feel spec, in code, and it
    /// is the part a test can pin. A test asserting that `.notFound` and
    /// `.lowConfidence` produce different haptic signatures is worth writing on
    /// day one.
    public func presentation(for outcome: OutcomeSignal) -> OutcomePresentation {
        switch outcome {
        case .arrived:
            OutcomePresentation(
                utterance: "You're on it.",
                haptics: taps(at: [0, 100, 200], intensity: [1, 1, 1], sharpness: 0.9),
                audio: nil,
                interrupts: true
            )
        case .lostTracking:
            OutcomePresentation(
                utterance: "Lost the panel. Point the camera at it again.",
                haptics: taps(at: [0, 250, 500], intensity: [0.9, 0.6, 0.3], sharpness: 0.2),
                audio: nil,
                interrupts: true
            )
        case .notFound:
            OutcomePresentation(
                utterance: "That button isn't on this panel.",
                haptics: taps(at: [0, 400], intensity: [0.8, 0.8], sharpness: 0.1),
                audio: nil,
                interrupts: true
            )
        case .lowConfidence:
            OutcomePresentation(
                utterance: "I'm not sure I see it. Try aiming again.",
                haptics: taps(at: [0, 70, 140, 210], intensity: [0.4, 0.4, 0.4, 0.4], sharpness: 0.7),
                audio: nil,
                interrupts: true
            )
        }
    }

    /// Announce `outcome`. Starts the effects and returns.
    ///
    /// Haptics only for now: speech waits on `SpeechQueue` and earcons on
    /// `DirectionalAudio`.
    public func announce(_ outcome: OutcomeSignal) async {
        let presentation = presentation(for: outcome)
        if presentation.interrupts {
            await player.stopPulsing()
        }
        await player.play(presentation.haptics)
    }

    private func taps(at milliseconds: [Int], intensity: [Double], sharpness: Double) -> [HapticEvent] {
        zip(milliseconds, intensity).map {
            HapticEvent(time: .milliseconds($0), intensity: $1, sharpness: sharpness)
        }
    }
}
