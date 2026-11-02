import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

@Suite("Guidance arrival hold")
struct GuidanceArrivalHoldTests {
    private func sample(_ distance: Double = 0, outcome: OutcomeSignal? = nil) -> GuidanceState {
        GuidanceState(timestamp: Date(), vector: GuidanceVector(direction: .zero, normalizedDistance: distance), outcome: outcome)
    }

    @Test("Geometric arrival is withheld until 1.25 seconds of fresh target samples")
    func dwell() {
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        for ms in stride(from: 0, through: 1200, by: 100) {
            let state = hold.update(sample(outcome: .arrived), at: epoch.advanced(by: .milliseconds(ms)))
            #expect(state.vector == .onTarget && state.outcome == nil)
        }
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1249))).outcome == nil)
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1250))).outcome == .arrived)
    }

    @Test("Leaving, losing the finger or unusable tracking cancels pending confirmation", arguments: [0, 1, 2, 3])
    func cancellation(reason: Int) {
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        for ms in stride(from: 0, through: 1000, by: 100) {
            _ = hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms)))
        }
        let interrupted: GuidanceState
        switch reason {
        case 0: interrupted = sample(0.1)
        case 1: interrupted = GuidanceState(timestamp: Date(), vector: nil)
        case 2: interrupted = .outcome(.lostTracking, at: Date())
        default: interrupted = .outcome(.lowConfidence, at: Date())
        }
        #expect(hold.update(interrupted, at: epoch.advanced(by: .milliseconds(1100))) == interrupted)
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1200))).outcome == nil)
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1300))).outcome == nil)
    }

    @Test("A stalled stream, backward clock or explicit session reset cannot complete an old hold")
    func discontinuities() {
        let epoch = ContinuousClock.now
        var hold = GuidanceArrivalHold()
        for ms in stride(from: 0, through: 1000, by: 100) {
            _ = hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms)))
        }
        #expect(hold.update(sample(), at: epoch.advanced(by: .seconds(3))).outcome == nil)
        #expect(hold.update(sample(), at: epoch).outcome == nil)
        hold.reset()
        #expect(hold.update(sample(), at: epoch.advanced(by: .seconds(4))).outcome == nil)
    }
}

@MainActor
@Suite("Hold rendering lifecycle")
struct HoldRenderingTests {
    @Test("On-target texture stays strong, respects mute and stops before confirmation")
    func texture() async {
        let haptics = HapticsExperienceEngine(onPulse: {})
        let engine = LiveFeedbackEngine(haptics: haptics)
        engine.setChannels(audio: false, voice: false, haptics: true, intensity: 0.9)
        await engine.present(GuidanceState(timestamp: Date(), vector: .onTarget))
        #expect(haptics.isHoldingTarget && haptics.continuousPlayerActive)
        #expect(haptics.intensity == 0.9 && haptics.sharpness == 0.12)
        #expect(!engine.didReachTarget)
        engine.setChannels(audio: false, voice: false, haptics: false)
        #expect(!haptics.isRunning)
        engine.setChannels(audio: false, voice: false, haptics: true)
        #expect(haptics.isHoldingTarget)
        await engine.present(.outcome(.arrived, at: Date()))
        #expect(engine.didReachTarget)
        #expect(!haptics.isHoldingTarget && !haptics.isRunning && !haptics.continuousPlayerActive)
        engine.stop()
    }

    @Test("One entry tap, uninterrupted hold, then one success haptic after 1.25 seconds")
    func threeStageFeedback() async {
        var taps = 0
        var successes = 0
        let haptics = HapticsExperienceEngine(onPulse: { taps += 1 }, onSuccess: { successes += 1 })
        let engine = LiveFeedbackEngine(haptics: haptics)
        engine.setChannels(audio: false, voice: false, haptics: true)
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        let target = GuidanceState(timestamp: Date(), vector: .onTarget)
        for ms in stride(from: 0, through: 1200, by: 100) {
            await engine.present(hold.update(target, at: epoch.advanced(by: .milliseconds(ms))))
            #expect(taps == 1 && successes == 0)
            #expect(haptics.isHoldingTarget && haptics.continuousPlayerActive)
        }
        let confirmed = hold.update(target, at: epoch.advanced(by: .milliseconds(1250)))
        await engine.present(confirmed)
        #expect(taps == 1 && successes == 1)
        #expect(!haptics.isRunning && !haptics.isHoldingTarget)
        await engine.present(confirmed)
        #expect(successes == 1, "Repeated arrival must not repeat confirmation")
        engine.stop()
        hold.reset()
        await engine.present(hold.update(target, at: epoch.advanced(by: .seconds(2))))
        #expect(taps == 2 && successes == 1)
        // Losing the finger cancels the hold; re-entry gets a fresh contact tap.
        await engine.present(GuidanceState(timestamp: Date(), vector: nil))
        await engine.present(target)
        #expect(taps == 3 && successes == 1)
        engine.stop()
        engine.setChannels(audio: false, voice: false, haptics: false)
        await engine.present(target)
        await engine.present(confirmed)
        #expect(taps == 3 && successes == 1, "Muted haptics emit neither entry nor success")
        engine.stop()
    }

    @Test("Freshness expiry silences a stalled hold and settings cannot revive it")
    func stale() async {
        let haptics = HapticsExperienceEngine(onPulse: {})
        let engine = LiveFeedbackEngine(haptics: haptics)
        engine.setChannels(audio: false, voice: false, haptics: true)
        await engine.present(GuidanceState(timestamp: Date(), vector: .onTarget))
        #expect(engine.expireStaleGuidance(at: ContinuousClock.now.advanced(by: .seconds(1))))
        #expect(!haptics.isRunning && !engine.didReachTarget)
        engine.setChannels(audio: false, voice: false, haptics: true)
        #expect(!haptics.isRunning)
        await engine.present(GuidanceState(timestamp: Date(), vector: .onTarget))
        #expect(haptics.isHoldingTarget && !engine.didReachTarget)
        engine.stop()
    }
}
