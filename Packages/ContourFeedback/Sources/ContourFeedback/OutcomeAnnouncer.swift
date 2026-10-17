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
//  V1 — TO BE CONFIRMED WITH DESIGN (KAYLEE)
//  The full spec, and why, is docs/decisions/outcome-signals.md. In short, each
//  outcome is a haptic signature, an earcon whose notes land with the taps, and
//  a line of speech that waits for the earcon to finish:
//    arrived        three strong, sharp taps · bright rising two-note chime
//    lostTracking   three taps fading out    · one tone gliding down and away
//    notFound       two heavy, dull taps     · low double "nope", second lower
//    lowConfidence  four light, quick taps   · a mid-pitch wavering trill
//  notFound and lowConfidence differ in register (low vs mid), rhythm (two slow
//  vs a fast flutter), contour (a falling step vs wavering) and touch (heavy and
//  dull vs light and crisp).
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

    /// The earcon's headline: its first note, as one cue. `earcon` holds the
    /// whole sound.
    public var audio: AudioCue?

    /// The full earcon for this outcome, if any.
    public var earcon: Earcon?

    /// Whether this interrupts whatever is currently playing.
    ///
    /// `arrived` almost certainly should. A continuous proximity pattern running
    /// underneath a success chime reads as "keep going".
    public var interrupts: Bool

    public init(
        utterance: String?,
        haptics: [HapticEvent],
        audio: AudioCue?,
        earcon: Earcon? = nil,
        interrupts: Bool
    ) {
        self.utterance = utterance
        self.haptics = haptics
        self.audio = audio
        self.earcon = earcon
        self.interrupts = interrupts
    }
}

/// Presents the four terminal signals.
public struct OutcomeAnnouncer: Sendable {

    private let player: HapticPlayer
    private let audio: DirectionalAudio?
    private let speech: SpeechQueue?

    /// Haptics, earcons and speech, with a speech queue of its own.
    public init() {
        self.init(audio: DirectionalAudio(), speech: SpeechQueue())
    }

    /// Haptics, plus earcons through `audio` and speech through `speech`. Pass
    /// `nil` to leave a channel out; share a queue so nothing talks over it.
    public init(audio: DirectionalAudio?, speech: SpeechQueue?) {
        self.init(player: HapticPlayer(), audio: audio, speech: speech)
    }

    /// Shares a player with the guidance model, so both use one haptic engine.
    /// Haptics only unless `audio` and `speech` are passed.
    init(player: HapticPlayer, audio: DirectionalAudio? = nil, speech: SpeechQueue? = nil) {
        self.player = player
        self.audio = audio
        self.speech = speech
    }

    /// How long an outcome line may wait to be said before it is stale.
    static let utteranceLifetime = Duration.seconds(3)

    /// How `outcome` should be presented.
    ///
    /// Pure and synchronous on purpose — this is the feel spec, in code, and it
    /// is the part a test can pin.
    public func presentation(for outcome: OutcomeSignal) -> OutcomePresentation {
        let earcon = Self.earcon(for: outcome)
        let headline = earcon.notes.first.map { AudioCue(pan: 0, pitch: $0.frequency, gain: $0.gain) }
        switch outcome {
        case .arrived:
            return OutcomePresentation(
                utterance: "You're on it.",
                haptics: taps(at: [0, 100, 200], intensity: [1, 1, 1], sharpness: 0.9),
                audio: headline,
                earcon: earcon,
                interrupts: true
            )
        case .lostTracking:
            return OutcomePresentation(
                utterance: "Lost the panel. Point the camera at it again.",
                haptics: taps(at: [0, 250, 500], intensity: [0.9, 0.6, 0.3], sharpness: 0.2),
                audio: headline,
                earcon: earcon,
                interrupts: true
            )
        case .notFound:
            return OutcomePresentation(
                utterance: "That button isn't on this panel.",
                haptics: taps(at: [0, 320], intensity: [0.9, 0.8], sharpness: 0.1),
                audio: headline,
                earcon: earcon,
                interrupts: true
            )
        case .lowConfidence:
            return OutcomePresentation(
                utterance: "I'm not sure I see it. Try aiming again.",
                haptics: taps(at: [0, 90, 180, 270], intensity: [0.4, 0.4, 0.4, 0.4], sharpness: 0.7),
                audio: headline,
                earcon: earcon,
                interrupts: true
            )
        }
    }

    /// The earcon for `outcome`. See docs/decisions/outcome-signals.md.
    static func earcon(for outcome: OutcomeSignal) -> Earcon {
        switch outcome {
        case .arrived:
            // A5 then E6, a rising fifth; the second note rings out.
            Earcon(notes: [
                EarconNote(start: .zero, duration: .milliseconds(100), frequency: 880, gain: 0.8, endGain: 0.6),
                EarconNote(start: .milliseconds(100), duration: .milliseconds(300), frequency: 1_319, gain: 0.8, endGain: 0.1),
            ])
        case .lostTracking:
            // One tone sliding down an octave as it fades: something slipping away.
            Earcon(notes: [
                EarconNote(start: .zero, duration: .milliseconds(500), frequency: 660, endFrequency: 330,
                           gain: 0.7, endGain: 0.05),
            ])
        case .notFound:
            // Low "no-pe": two heavy notes, the second a step lower. Lands with the taps.
            Earcon(notes: [
                EarconNote(start: .zero, duration: .milliseconds(150), frequency: 233, gain: 0.9, endGain: 0.5),
                EarconNote(start: .milliseconds(320), duration: .milliseconds(200), frequency: 196, gain: 0.9, endGain: 0.4),
            ])
        case .lowConfidence:
            // D5 / E5 trill: eight even 45 ms notes wavering up and down. Unsure.
            Earcon(notes: (0..<8).map { index in
                EarconNote(start: .milliseconds(45 * index), duration: .milliseconds(45),
                           frequency: index.isMultiple(of: 2) ? 587 : 659, gain: 0.5)
            })
        }
    }

    /// The line to queue for `presentation`, or `nil` if it says nothing.
    /// Interrupting outcomes cut in; the rest wait their turn. When an earcon
    /// plays, the words wait for it to finish.
    static func utterance(for presentation: OutcomePresentation, withEarcon: Bool) -> Utterance? {
        guard let text = presentation.utterance else { return nil }
        return Utterance(
            text: text,
            priority: presentation.interrupts ? .interrupting : .normal,
            expiresAfter: utteranceLifetime,
            leadIn: withEarcon ? presentation.earcon?.duration ?? .zero : .zero
        )
    }

    /// Announce `outcome`: haptics, earcon and speech. Starts the effects and
    /// returns; never waits for the taps, the sound or the words to finish.
    public func announce(_ outcome: OutcomeSignal) async {
        let presentation = presentation(for: outcome)
        if presentation.interrupts {
            await player.stopPulsing()
            await audio?.stop()   // the guidance tone under a chime reads as "keep going"
        }
        await player.play(presentation.haptics)

        var playedEarcon = false
        if let audio, let earcon = presentation.earcon {
            await audio.play(earcon)
            playedEarcon = true
        }
        if let speech, let line = Self.utterance(for: presentation, withEarcon: playedEarcon) {
            await speech.enqueue(line)
        }
    }

    private func taps(at milliseconds: [Int], intensity: [Double], sharpness: Double) -> [HapticEvent] {
        zip(milliseconds, intensity).map {
            HapticEvent(time: .milliseconds($0), intensity: $1, sharpness: sharpness)
        }
    }
}
