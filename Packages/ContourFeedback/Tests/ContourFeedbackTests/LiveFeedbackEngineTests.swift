//
//  LiveFeedbackEngineTests.swift
//  ContourFeedbackTests — Experience / Outcome Signals & Harness
//
//  Pins how LiveFeedbackEngine routes each frame (#109, #113, #114, #119): what
//  the model, the tone, the hint and the outcome signals each do, through the
//  same FeedbackRouter the engine uses. The router is pure, so nothing here
//  plays a sound; the end-to-end tests use a private haptic player and no
//  audio or speech.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

private func guiding(_ dx: Double, _ dy: Double, distance: Double = 0.5, at seconds: Double = 0) -> GuidanceState {
    GuidanceState(
        timestamp: Date(timeIntervalSince1970: seconds),
        vector: GuidanceVector(direction: PanelVector(dx: dx, dy: dy), normalizedDistance: distance)
    )
}

private func noFinger(at seconds: Double = 0) -> GuidanceState {
    GuidanceState(timestamp: Date(timeIntervalSince1970: seconds), vector: nil)
}

private func outcome(_ outcome: OutcomeSignal, at seconds: Double = 0) -> GuidanceState {
    .outcome(outcome, at: Date(timeIntervalSince1970: seconds))
}

/// A router with the real tone mapping. Its ToneEngine is private and never
/// started: routing only computes cues.
private func router(hint: Bool = false) -> FeedbackRouter {
    FeedbackRouter(audio: DirectionalAudio(tone: ToneEngine(harmonic: true)), hintEnabled: hint)
}

@Suite("LiveFeedbackEngine routing")
struct LiveFeedbackEngineTests {

    // MARK: Guiding frames (#113)

    @Test("a guiding frame renders the model and plays the tone's cue for that state")
    func guidingRendersModelAndTone() {
        var subject = router()
        let state = guiding(0.6, -0.8, distance: 0.3)
        let plan = subject.route(state)
        #expect(plan.guidance == .render)
        #expect(plan.tone == .play(subject.audio!.cue(for: state)!))
        #expect(plan.announce == nil)
    }

    @Test("+dy is down: through the engine, a target ABOVE the finger sounds HIGHER")
    func targetAboveSoundsHigherThroughTheEngine() throws {
        var subject = router()
        guard case .play(let above) = subject.route(guiding(0, -1)).tone,
              case .play(let below) = subject.route(guiding(0, 1)).tone,
              case .play(let level) = subject.route(guiding(1, 0)).tone
        else {
            Issue.record("guiding frames must play the tone")
            return
        }
        #expect(above.pitch > level.pitch)
        #expect(level.pitch > below.pitch)
        #expect(above.pitch == DirectionalAudio.highPitch)
        #expect(level.pan > 0, "a target to the right pans right")
    }

    @Test("closer is louder through the engine")
    func closerIsLouderThroughTheEngine() {
        var subject = router()
        guard case .play(let far) = subject.route(guiding(0, 1, distance: 0.9)).tone,
              case .play(let near) = subject.route(guiding(0, 1, distance: 0.1)).tone
        else {
            Issue.record("guiding frames must play the tone")
            return
        }
        #expect(near.gain > far.gain)
    }

    @Test("a frame with no finger silences the model and the tone")
    func noVectorSilences() {
        var subject = router()
        let plan = subject.route(noFinger())
        #expect(plan.guidance == .silence)
        #expect(plan.tone == .stop)
        #expect(plan.announce == nil)
    }

    @Test("with audio off, the tone is never touched")
    func audioOffLeavesToneAlone() {
        var subject = FeedbackRouter(audio: nil, hintEnabled: false)
        #expect(subject.route(guiding(0, -1)).tone == .unchanged)
        #expect(subject.route(noFinger()).tone == .unchanged)
        #expect(subject.route(outcome(.arrived)).tone == .unchanged)
    }

    // MARK: Outcomes (#109, #55)

    @Test("every outcome silences guidance and the tone, and is announced", arguments: OutcomeSignal.allCases)
    func outcomeSilencesAndAnnounces(signal: OutcomeSignal) {
        var subject = router()
        _ = subject.route(guiding(0, -1))
        let plan = subject.route(outcome(signal))
        #expect(plan.guidance == .silence)
        #expect(plan.tone == .stop)
        #expect(plan.announce == signal)
    }

    @Test("an outcome repeated frame after frame is announced once, but keeps everything quiet")
    func repeatedOutcomeIsAnnouncedOnce() {
        var subject = router()
        #expect(subject.route(outcome(.arrived, at: 0)).announce == .arrived)
        for frame in 1...120 {
            let plan = subject.route(outcome(.arrived, at: Double(frame) / 60))
            #expect(plan.announce == nil)
            #expect(plan.guidance == .silence && plan.tone == .stop)
        }
    }

    @Test("a finger wobbling on the edge doesn't re-announce; a real second arrival does")
    func flickerIsNotReannounced() {
        var subject = router()
        #expect(subject.route(outcome(.arrived, at: 0)).announce == .arrived)
        _ = subject.route(guiding(0, 1, distance: 0.06, at: 0.2))
        #expect(subject.route(outcome(.arrived, at: 0.3)).announce == nil, "within 2 s of the last one")
        _ = subject.route(guiding(0, 1, distance: 0.3, at: 3))
        #expect(subject.route(outcome(.arrived, at: 5)).announce == .arrived, "guided again, and 2 s on")
    }

    @Test("a different outcome is announced straight away")
    func differentOutcomeIsAnnounced() {
        var subject = router()
        #expect(subject.route(outcome(.lowConfidence, at: 0)).announce == .lowConfidence)
        #expect(subject.route(outcome(.notFound, at: 0.1)).announce == .notFound)
    }

    @Test("reset forgets the last outcome, so a new session hears its own")
    func resetForgetsOutcomes() {
        var subject = router()
        #expect(subject.route(outcome(.arrived, at: 0)).announce == .arrived)
        subject.reset()
        #expect(subject.route(outcome(.arrived, at: 0.1)).announce == .arrived)
    }

    // MARK: Directional hint (#119)

    @Test("the directional hint is off unless switched on")
    func hintIsOffByDefault() {
        var subject = router()
        #expect(subject.route(guiding(0, -1)).hint == nil)
    }

    @Test("switched on, the hint follows the dominant axis, +dy down, rate-limited")
    func hintWhenEnabled() {
        var subject = router(hint: true)
        #expect(subject.route(guiding(0.2, -0.9, at: 0)).hint == .up)
        #expect(subject.route(guiding(0.2, -0.9, at: 0.5)).hint == nil)
        #expect(subject.route(guiding(0.1, 0.95, at: 1)).hint == .down)
    }

    @Test("no hint right after an outcome")
    func noHintAfterAnOutcome() {
        var subject = router(hint: true)
        _ = subject.route(outcome(.lostTracking, at: 0))
        #expect(subject.route(guiding(0, -1, at: 0.5)).hint == nil)
        #expect(subject.route(guiding(0, -1, at: 2)).hint == .up)
    }

    // MARK: Ducking (#114)

    @Test("the tone keeps full level in silence, a quarter under speech, none under an interrupting line")
    func duckFactor() {
        #expect(DirectionalAudio.duckFactor(for: .silent) == 1)
        #expect(DirectionalAudio.duckFactor(for: .speaking(.normal)) == 0.25)
        #expect(DirectionalAudio.duckFactor(for: .speaking(.low)) == 0.25)
        #expect(DirectionalAudio.duckFactor(for: .speaking(.interrupting)) == 0)
    }

    @Test("the ducked level is the cue's gain times volume times duck, and silence when unwanted")
    func duckedLevel() {
        #expect(ToneEngine.level(gain: 0.8, volume: 1, duck: 0.25, wanted: true) == 0.2)
        #expect(ToneEngine.level(gain: 0.8, volume: 0.5, duck: 1, wanted: true) == 0.4)
        #expect(ToneEngine.level(gain: 0.8, volume: 1, duck: 1, wanted: false) == 0)
    }

    @Test("ducking the tone sets its duck, and lifting it restores full level")
    func duckingDrivesTheTone() async {
        let tone = ToneEngine(harmonic: true)
        let audio = DirectionalAudio(tone: tone)
        await audio.duck(for: .speaking(.normal))
        #expect(await tone.duck == 0.25)
        await audio.duck(for: .silent)
        #expect(await tone.duck == 1)
    }

    // MARK: End to end, haptics only

    @MainActor
    @Test("through the engine: guiding vibrates, no finger and outcomes go quiet, stop is clean",
          arguments: GuidanceModelKind.allCases)
    func engineDrivesTheModel(model: GuidanceModelKind) async {
        let player = HapticPlayer()
        let engine = LiveFeedbackEngine(model: model, player: player, audio: nil, speech: nil, directionalHint: false)
        let vibrating = { player.isPulsing || player.isSustaining }

        await engine.present(guiding(0, -1, distance: 0.4))
        #expect(vibrating())
        #expect(model == .continuousProximity ? player.isSustaining : player.isPulsing)

        await engine.present(noFinger())
        #expect(!vibrating())

        await engine.present(guiding(0, -1, distance: 0.4))
        await engine.present(outcome(.arrived))
        #expect(!vibrating(), "an outcome must not leave guidance buzzing")

        await engine.present(guiding(0, -1, distance: 0.4))
        await engine.stop()
        #expect(!vibrating())
        await engine.stop()   // safe when idle
    }

    @Test("the public initialisers pick the chosen model and the right channels")
    func publicInitialisers() {
        let chosen = LiveFeedbackEngine()
        #expect(chosen.model == ChosenGuidanceModel.current)
        #expect(chosen.playsAudio && chosen.speaks && !chosen.hintsDirection)

        let quiet = LiveFeedbackEngine(model: .pulsedProximity, audio: false, speech: false, directionalHint: true)
        #expect(quiet.model == .pulsedProximity)
        #expect(!quiet.playsAudio && !quiet.speaks && quiet.hintsDirection)
    }
}
