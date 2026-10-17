//
//  GuidanceModelTests.swift
//  ContourFeedbackTests — Experience / Haptics
//
//  Pins the two bake-off models (#17): both only ever get stronger or faster as
//  the finger closes in, the continuous one really is sustained (#120), and
//  switching models or losing the finger never leaves a vibration on. On a Mac
//  there is no haptic hardware, so playing anything here is a safe no-op; the
//  assertions are on what the manager was asked to do.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

private func state(distance: Double?, outcome: OutcomeSignal? = nil) -> GuidanceState {
    GuidanceState(
        timestamp: Date(timeIntervalSince1970: 0),
        vector: distance.map { GuidanceVector(direction: PanelVector(dx: 0, dy: -1), normalizedDistance: $0) },
        outcome: outcome
    )
}

/// Every hundredth from well before the button to well off the panel, nearest first.
private let sweep = stride(from: -0.5, through: 2.5, by: 0.01).map { $0 }

@Suite("Guidance models")
struct GuidanceModelTests {

    // MARK: Continuous

    @Test("continuous: the buzz never gets weaker or duller as the finger closes in")
    func continuousOnlyStrengthens() throws {
        let buzzes = try sweep.map { try #require(ContinuousProximityModel.buzz(forDistance: $0)) }
        for (nearer, farther) in zip(buzzes, buzzes.dropFirst()) {
            #expect(farther.intensity <= nearer.intensity)
            #expect(farther.sharpness <= nearer.sharpness)
        }
        let onTarget = try #require(ContinuousProximityModel.buzz(forDistance: 0))
        let atEdge = try #require(ContinuousProximityModel.buzz(forDistance: 1))
        #expect(onTarget.intensity > atEdge.intensity)
        #expect(onTarget.sharpness > atEdge.sharpness)
    }

    @Test("continuous: the throb only ever speeds up as the finger closes in")
    func continuousThrobOnlySpeedsUp() throws {
        // A steady buzz counts as infinitely slow.
        let periods = try sweep.map {
            try #require(ContinuousProximityModel.buzz(forDistance: $0)).throbPeriod ?? .seconds(1_000)
        }
        for (nearer, farther) in zip(periods, periods.dropFirst()) {
            #expect(farther >= nearer)
        }
        #expect(ContinuousProximityModel.buzz(forDistance: 0)?.throbPeriod == .milliseconds(120))
        #expect(ContinuousProximityModel.buzz(forDistance: 0.5)?.throbPeriod == nil, "mid-panel is a steady buzz")
        #expect(ContinuousProximityModel.buzz(forDistance: GuidanceTuning.throbZone)?.throbPeriod == nil)
    }

    @Test("continuous: never too faint to feel, and off the panel feels like the edge")
    func continuousFloorAndClamp() throws {
        for distance in sweep + [.infinity] {
            let buzz = try #require(ContinuousProximityModel.buzz(forDistance: distance))
            #expect(buzz.intensity >= 0.2 && buzz.intensity <= 1)
            #expect(buzz.sharpness >= 0 && buzz.sharpness <= 1)
        }
        #expect(ContinuousProximityModel.buzz(forDistance: 2.5) == ContinuousProximityModel.buzz(forDistance: 1))
        #expect(ContinuousProximityModel.buzz(forDistance: -0.2) == ContinuousProximityModel.buzz(forDistance: 0))
        #expect(ContinuousProximityModel.buzz(forDistance: .nan) == nil)
    }

    @Test("continuous: the weak half of a throb is still a buzz, not silence")
    func throbNeverDropsToSilence() {
        #expect(GuidanceTuning.throbDip > 0 && GuidanceTuning.throbDip < 1)
    }

    // MARK: Pulsed

    @Test("pulsed: pulses never slow down or soften as the finger closes in")
    func pulsedOnlySpeedsUp() throws {
        for (nearer, farther) in zip(sweep, sweep.dropFirst()) {
            #expect(ProximityHaptics.pulseInterval(forDistance: farther) >= ProximityHaptics.pulseInterval(forDistance: nearer))
            let near = try #require(ProximityHaptics.beat(forDistance: nearer))
            let far = try #require(ProximityHaptics.beat(forDistance: farther))
            #expect(far.intensity <= near.intensity)
            #expect(far.sharpness <= near.sharpness)
        }
    }

    // MARK: Playing them

    @MainActor
    @Test("continuous: a guiding frame holds a sustained buzz at the mapped level")
    func continuousIsSustained() async throws {
        let player = HapticPlayer()
        let model = ContinuousProximityModel(player: player)

        await model.render(state(distance: 0.6))
        #expect(player.isSustaining && !player.isPulsing)
        let engine = try #require(player.manager)
        let expected = try #require(ContinuousProximityModel.buzz(forDistance: 0.6))
        #expect(engine.wantsRunning, "a reset or a trip to the background resumes it")
        #expect(abs(Double(engine.currentIntensity) - expected.intensity) < 1e-6,
                "the level a reset re-applies is the one guidance asked for")

        await model.render(state(distance: 0.3))
        let closer = try #require(ContinuousProximityModel.buzz(forDistance: 0.3))
        #expect(abs(Double(engine.currentIntensity) - closer.intensity) < 1e-6)

        await model.stop()
    }

    @MainActor
    @Test("continuous: no finger, an outcome, or stop silences the buzz", arguments: [0, 1, 2])
    func continuousNeverSticks(way: Int) async throws {
        let player = HapticPlayer()
        let model = ContinuousProximityModel(player: player)

        await model.render(state(distance: 0.05))   // inside the throb zone: a loop is running
        let engine = try #require(player.manager)
        #expect(player.isSustaining)

        switch way {
        case 0: await model.render(state(distance: nil))
        case 1: await model.render(state(distance: 0, outcome: .arrived))
        default: await model.stop()
        }
        #expect(!player.isSustaining)
        #expect(!engine.wantsRunning, "nothing will resume it after a reset")
        #expect(engine.currentIntensity == 0, "a later start must open silent")
    }

    @MainActor
    @Test("pulsed: an outcome frame stops the pulses")
    func pulsedStopsOnOutcome() async {
        let player = HapticPlayer()
        let model = PulsedProximityModel(player: player)
        await model.render(state(distance: 0.5))
        #expect(player.isPulsing)
        await model.render(state(distance: 0, outcome: .arrived))
        #expect(!player.isPulsing)
    }

    @MainActor
    @Test("switching models mid-run leaves only the new one playing, then nothing")
    func switchingModelsNeverSticks() async throws {
        let player = HapticPlayer()
        let continuous = GuidanceModelKind.continuousProximity.makeModel(player: player)
        let pulsed = GuidanceModelKind.pulsedProximity.makeModel(player: player)

        await continuous.render(state(distance: 0.4))
        #expect(player.isSustaining)

        await continuous.stop()
        await pulsed.render(state(distance: 0.4))
        #expect(player.isPulsing && !player.isSustaining)

        // Even without a stop in between, the player runs one kind at a time.
        await continuous.render(state(distance: 0.4))
        #expect(player.isSustaining && !player.isPulsing)

        await pulsed.stop()
        #expect(!player.isSustaining && !player.isPulsing)
        let engine = try #require(player.manager)
        #expect(!engine.wantsRunning)
    }

    @Test("every kind builds the model it names")
    func kindsBuildTheirModels() {
        for kind in GuidanceModelKind.allCases {
            #expect(kind.makeModel(player: HapticPlayer()).kind == kind)
            #expect(!kind.displayName.isEmpty)
        }
    }
}
