//
//  LiveFeedbackEngine.swift
//  ContourFeedback — Experience / Outcome Signals & Harness
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  HAPTICS, AUDIO AND SPEECH.                                              │
//  │                                                                          │
//  │  Every guiding frame goes to:                                            │
//  │    the guidance model   haptics: ChosenGuidanceModel unless you pick one  │
//  │    DirectionalAudio     the tone: pan = left/right, pitch = up/down       │
//  │    DirectionalHint      optional haptic up/down/left/right, off by default│
//  │  Every outcome silences all of that and plays OutcomeAnnouncer's haptics, │
//  │  earcon and line, the line through SpeechQueue. The tone ducks while      │
//  │  speech plays. Audio, speech and the hint are switches on `init`.         │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  Haptics, audio, speech, and the four outcome signals. Everything the user
//  perceives that is not on screen.
//
//  YOU ARE NOT BLOCKED BY ANYONE
//  This package reads exactly one type — GuidanceState — and that type is
//  already frozen-shaped and already mocked. You do not need a camera, a phone,
//  or Surface Understanding and Tracking to start. Run the Harness:
//
//      open Contour.xcworkspace     # then run the `Harness` scheme, My Mac
//
//  Sliders for the fingertip, a picker for tracking quality, four buttons for
//  the four outcomes, and pickers for the engine and the model. That is your
//  blindfold rig. Use it from day one.
//
//  COORDINATES
//  `GuidanceState.vector.direction` is in normalized panel space: +dx is right,
//  +dy is DOWN. A direction of (0, -1) means "move the finger UP the panel",
//  and sounds HIGHER. Get this backwards and every user goes the wrong way.
//  See Packages/ContourCore/COORDINATES.md.
//
//  ONE PERFORMANCE NOTE
//  `present(_:)` is called at camera rate. Start an effect and return — never
//  await the full duration of a haptic pattern or an utterance. Each frame is
//  applied in one synchronous step on the main actor (FeedbackSession), so a
//  later frame can never overtake an earlier one and leave something playing.
//  Speech is handed to SpeechQueue in order through a pipe and never awaited.
//
//  REPEATED OUTCOMES
//  A pipeline reports the same outcome on every frame while it holds —
//  MockGuidance sends `arrived` at camera rate while the finger sits on the
//  button. An outcome is announced once, and the same one again only after
//  guidance has resumed in between AND two seconds have passed, so a finger
//  wobbling on the edge of the button doesn't re-announce every frame.
//
//  ENDING A SESSION
//  Call `stop()` when a guidance session ends or before switching engines: it
//  silences every channel, drops queued and current speech, and forgets the
//  outcome history, so the next session starts clean and hears nothing stale.
//  Outcome lines also expire after three seconds unsaid.
//

import ContourCore
import Foundation

/// The real feedback engine: guidance you feel and hear, and outcomes you are told.
public struct LiveFeedbackEngine: FeedbackEngine {

    /// The guidance model this engine runs.
    public let model: GuidanceModelKind

    /// Whether the directional tone and the outcome earcons play.
    public let playsAudio: Bool

    /// Whether outcome lines are spoken.
    public let speaks: Bool

    /// Whether the directional haptic hint fires.
    public let hintsDirection: Bool

    private let session: FeedbackSession

    /// The chosen model (`ChosenGuidanceModel.current`), with audio and speech
    /// on and the directional hint off.
    public init() {
        self.init(model: ChosenGuidanceModel.current)
    }

    /// Pick the guidance model and which channels run.
    ///
    /// - Parameters:
    ///   - model: the haptic guidance model. `ChosenGuidanceModel.current` is
    ///     the decided one.
    ///   - audio: the directional tone and the outcome earcons.
    ///   - speech: spoken outcome lines.
    ///   - directionalHint: occasional haptic up/down/left/right corrections,
    ///     for when the tone can't be heard (#119). Off by default.
    ///
    /// Every engine shares one haptic player and one tone, so a new engine
    /// takes over from an old one rather than playing alongside it. Still,
    /// `stop()` the old one first: its speech queue is its own.
    public init(model: GuidanceModelKind, audio: Bool = true, speech: Bool = true, directionalHint: Bool = false) {
        self.init(
            model: model,
            player: .shared,
            audio: audio ? DirectionalAudio() : nil,
            speech: speech ? SpeechQueue() : nil,
            directionalHint: directionalHint
        )
    }

    /// Everything injected, for tests: a private player, and no audio or speech
    /// so nothing plays on the machine running them.
    init(
        model: GuidanceModelKind,
        player: HapticPlayer,
        audio: DirectionalAudio?,
        speech: SpeechQueue?,
        directionalHint: Bool
    ) {
        self.model = model
        self.playsAudio = audio != nil
        self.speaks = speech != nil
        self.hintsDirection = directionalHint
        session = FeedbackSession(
            model: model.makeModel(player: player),
            player: player,
            audio: audio,
            speech: speech,
            directionalHint: directionalHint
        )
    }

    /// Present one moment of guidance as haptics, audio, and speech.
    ///
    /// A state with a non-`nil` `outcome` is terminal: guidance goes quiet and
    /// the corresponding signal plays for `arrived`, `lostTracking`, `notFound`,
    /// or `lowConfidence`. Otherwise the model and the tone follow the vector,
    /// and a state with no vector (no finger seen) goes quiet.
    public func present(_ state: GuidanceState) async {
        await session.present(state)
    }

    /// End the session: silence every channel, cut and drop speech, and forget
    /// outcome history. Safe to call when idle. Call it before switching to
    /// another engine or model, and when guidance ends.
    public func stop() async {
        await session.stop()
    }
}

// MARK: - Routing (pure)

/// What one frame does to each channel.
struct FeedbackPlan: Equatable {

    enum Guidance: Equatable {
        case render, silence, unchanged
    }

    enum Tone: Equatable {
        case play(AudioCue), stop, unchanged
    }

    var guidance: Guidance = .unchanged
    var tone: Tone = .unchanged
    var hint: HintDirection?
    var announce: OutcomeSignal?
}

/// Decides what each frame does. Pure apart from its own small memory of the
/// last outcome and the last hint, both measured on the states' timestamps, so
/// every routing rule is unit-tested without playing anything.
struct FeedbackRouter: Sendable {

    /// The tone's mapping, or `nil` when audio is off.
    let audio: DirectionalAudio?
    let hintEnabled: Bool

    /// The same outcome is not re-announced within this long, even if guidance
    /// flickered back in between, seconds.
    static let outcomeRepeatInterval = 2.0

    private var hint = DirectionalHint()
    private var lastAnnounced: (outcome: OutcomeSignal, time: Date)?
    private var guidedSinceLastOutcome = true

    init(audio: DirectionalAudio?, hintEnabled: Bool) {
        self.audio = audio
        self.hintEnabled = hintEnabled
    }

    mutating func route(_ state: GuidanceState) -> FeedbackPlan {
        var plan = FeedbackPlan()

        if let outcome = state.outcome {
            // Terminal: everything guiding goes quiet, every time.
            plan.guidance = .silence
            plan.tone = audio == nil ? .unchanged : .stop
            if !isRepeat(outcome, at: state.timestamp) {
                plan.announce = outcome
                lastAnnounced = (outcome, state.timestamp)
                guidedSinceLastOutcome = false
                hint.outcomeHappened(at: state.timestamp)
            }
            return plan
        }

        guard state.vector != nil else {
            // No finger, no target: quiet, but not a new session.
            plan.guidance = .silence
            plan.tone = audio == nil ? .unchanged : .stop
            return plan
        }

        guidedSinceLastOutcome = true
        plan.guidance = .render
        if let audio {
            plan.tone = audio.cue(for: state).map(FeedbackPlan.Tone.play) ?? .stop
        }
        if hintEnabled {
            plan.hint = hint.next(for: state)
        }
        return plan
    }

    /// Forget everything, for a new session.
    mutating func reset() {
        hint = DirectionalHint()
        lastAnnounced = nil
        guidedSinceLastOutcome = true
    }

    private func isRepeat(_ outcome: OutcomeSignal, at time: Date) -> Bool {
        guard let last = lastAnnounced, last.outcome == outcome else { return false }
        if !guidedSinceLastOutcome { return true }
        let elapsed = time.timeIntervalSince(last.time)
        return elapsed >= 0 && elapsed < Self.outcomeRepeatInterval
    }
}

// MARK: - Playing it

/// Applies each frame's plan to the channels, on the main actor, in one step.
@MainActor
final class FeedbackSession {

    private var router: FeedbackRouter
    private let model: any MainActorGuidanceModel
    private let player: HapticPlayer
    private let audio: DirectionalAudio?
    private let announcer: OutcomeAnnouncer

    /// Speech commands, in order, to the one task that talks to SpeechQueue.
    /// Yielding is synchronous, so a `stop` can never overtake the line before it.
    private let speech: AsyncStream<SpeechCommand>.Continuation?

    private enum SpeechCommand: Sendable {
        case say(Utterance)
        case stop
    }

    nonisolated init(
        model: any MainActorGuidanceModel,
        player: HapticPlayer,
        audio: DirectionalAudio?,
        speech queue: SpeechQueue?,
        directionalHint: Bool
    ) {
        router = FeedbackRouter(audio: audio, hintEnabled: directionalHint)
        self.model = model
        self.player = player
        self.audio = audio
        announcer = OutcomeAnnouncer(player: player, audio: audio)

        guard let queue else {
            speech = nil
            return
        }
        let (commands, continuation) = AsyncStream.makeStream(of: SpeechCommand.self)
        speech = continuation
        Task {
            for await command in commands {
                switch command {
                case .say(let line): await queue.enqueue(line)
                case .stop: await queue.stop()
                }
            }
        }
        // Duck the tone while a line is being said (#114).
        if let audio {
            let activity = queue.activityUpdates()
            Task {
                for await now in activity {
                    await audio.duck(for: now)
                }
            }
        }
    }

    deinit {
        speech?.finish()
    }

    func present(_ state: GuidanceState) {
        let plan = router.route(state)

        switch plan.guidance {
        case .render: model.apply(state)
        case .silence: model.silence()
        case .unchanged: break
        }

        switch plan.tone {
        case .play(let cue): audio?.render(cue)
        case .stop: audio?.silence()
        case .unchanged: break
        }

        if let direction = plan.hint {
            player.play(DirectionalHint.signature(for: direction))
        }

        if let outcome = plan.announce, let line = announcer.perform(outcome) {
            speech?.yield(.say(line))
        }
    }

    func stop() {
        router.reset()
        model.silence()
        audio?.silence()
        speech?.yield(.stop)
    }
}
