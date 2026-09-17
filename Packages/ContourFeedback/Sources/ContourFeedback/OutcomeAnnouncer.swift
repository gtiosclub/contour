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

    public init() {}

    /// How `outcome` should be presented.
    ///
    /// Pure and synchronous on purpose — this is the feel spec, in code, and it
    /// is the part a test can pin. A test asserting that `.notFound` and
    /// `.lowConfidence` produce different haptic signatures is worth writing on
    /// day one.
    public func presentation(for outcome: OutcomeSignal) -> OutcomePresentation {
        fatalError("unimplemented — owned by Experience / Outcome Signals & Harness")
    }

    /// Announce `outcome`. Starts the effects and returns.
    public func announce(_ outcome: OutcomeSignal) async {
        fatalError("unimplemented — owned by Experience / Outcome Signals & Harness")
    }
}
