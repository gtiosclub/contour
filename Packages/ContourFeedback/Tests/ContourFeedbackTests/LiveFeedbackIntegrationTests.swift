import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

@MainActor
@Suite("Shared experience guidance")
struct LiveFeedbackIntegrationTests {
    private func state(_ distance: Double, dx: Double = 1, dy: Double = 0) -> GuidanceState {
        GuidanceState(timestamp: Date(), vector: GuidanceVector(
            direction: PanelVector(dx: dx, dy: dy), normalizedDistance: distance))
    }

    @Test("Direction locks an axis, then confirms an actual overshoot")
    func directionLock() {
        var policy = ExperienceDirectionInstruction()
        policy.update(state(0.5, dx: 0.8, dy: 0.6).vector!, at: 1)
        #expect(policy.voiceGuidance == .direction(.right, near: false))
        policy.update(state(0.5, dx: 0.2, dy: 0.98).vector!, at: 2)
        #expect(policy.voiceGuidance == .direction(.right, near: false))
        policy.update(state(0.5, dx: -0.2, dy: 0.98).vector!, at: 3)
        #expect(policy.voiceGuidance == .direction(.right, near: false))
        policy.update(state(0.5, dx: -0.2, dy: 0.98).vector!, at: 3.13)
        #expect(policy.voiceGuidance == .direction(.left, near: false))
    }

    @Test("Zero distance alone does not invent arrival")
    func zeroDistance() async {
        let engine = LiveFeedbackEngine()
        engine.setChannels(audio: false, voice: false, haptics: false)
        await engine.present(state(0))
        #expect(!engine.didReachTarget)
        #expect(engine.instructionText == "Stop. Hold here.")
        await engine.present(.outcome(.arrived, at: Date()))
        #expect(engine.didReachTarget)
        await engine.present(.outcome(.arrived, at: Date()))
        #expect(engine.didReachTarget)
        await engine.present(state(0.4))
        #expect(!engine.didReachTarget)
        engine.stop()
    }

    @Test("Missing or invalid guidance resets arrival and direction; stop is repeatable")
    func reset() async {
        let engine = LiveFeedbackEngine()
        engine.setChannels(audio: false, voice: false, haptics: false)
        await engine.present(.outcome(.arrived, at: Date()))
        await engine.present(GuidanceState(timestamp: Date(), vector: nil))
        #expect(!engine.didReachTarget)
        await engine.present(state(.nan))
        #expect(engine.instructionText == "Guidance paused.")
        engine.stop()
        engine.stop()
        #expect(!engine.audio.isRunning && !engine.voice.isRunning && !engine.haptics.isRunning)
        #expect(engine.instructionText == "Press Start to begin.")
    }

    @Test("Guidance drives shared beats and stop cancels them before restart")
    func playbackLifecycle() async throws {
        var beats = 0
        let haptics = HapticsExperienceEngine(onPulse: { beats += 1 })
        let engine = LiveFeedbackEngine(haptics: haptics)
        engine.setChannels(audio: false, voice: false, haptics: true)
        await engine.present(state(0.8))
        #expect(haptics.isRunning && haptics.mode == .pulsed)
        // Yield to the shared scheduler; its first beat is immediate.
        try await Task.sleep(for: .milliseconds(30))
        #expect(beats > 0)
        await engine.present(state(0.2))
        #expect(haptics.mode == .continuous && haptics.continuousPlayerActive)
        engine.setChannels(audio: false, voice: false, haptics: false)
        #expect(!haptics.isRunning)
        engine.setChannels(audio: false, voice: false, haptics: true)
        #expect(haptics.isRunning)
        engine.stop()
        let stoppedBeats = beats
        try await Task.sleep(for: .milliseconds(30))
        #expect(beats == stoppedBeats && !haptics.isRunning)
        // Changing settings after stop must not revive the previous guidance.
        engine.setChannels(audio: false, voice: false, haptics: true)
        #expect(!haptics.isRunning)
        await engine.present(state(0.8))
        #expect(haptics.isRunning && haptics.mode == .pulsed)
        await engine.present(GuidanceState(timestamp: Date(), vector: nil))
        #expect(!haptics.isRunning)
    }

    @Test("Channel settings are independent and intensity is clamped")
    func settings() {
        let engine = LiveFeedbackEngine()
        engine.setChannels(audio: false, voice: true, haptics: false, intensity: 2)
        #expect(!engine.audioEnabled && engine.voiceEnabled && !engine.hapticsEnabled)
        #expect(engine.haptics.overallIntensity == 1)
        engine.setChannels(audio: true, voice: false, haptics: true, intensity: -1)
        #expect(engine.audioEnabled && !engine.voiceEnabled && engine.hapticsEnabled)
        #expect(engine.haptics.overallIntensity == 0)
        engine.stop()
    }
}
