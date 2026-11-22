import ContourCore
import ContourMocks
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

    @Test("Leaving, losing the panel or unusable tracking cancels pending confirmation", arguments: [0, 1, 2])
    func cancellation(reason: Int) {
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        for ms in stride(from: 0, through: 1000, by: 100) {
            _ = hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms)))
        }
        let interrupted: GuidanceState
        switch reason {
        case 0: interrupted = sample(0.1)
        case 1: interrupted = .outcome(.lostTracking, at: Date())
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

    private let missed = GuidanceState(timestamp: Date(), vector: nil)

    @Test("A frame that missed the fingertip keeps a pending hold going, but can't complete it")
    func missedFingertip() {
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        #expect(hold.update(missed, at: epoch) == missed, "There's no hold to keep yet")
        for ms in stride(from: 100, through: 1000, by: 100) {
            _ = hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms)))
        }
        // Hand pose misses the finger for 400 ms, past the end of the hold.
        for ms in [1100, 1200, 1300, 1400] {
            let state = hold.update(missed, at: epoch.advanced(by: .milliseconds(ms)))
            #expect(state.vector == .onTarget && state.outcome == nil)
        }
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1450))).outcome == .arrived)
    }

    @Test("A stall shorter than half a second keeps the hold, which still takes 1.25 seconds")
    func briefStall() {
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        for ms in stride(from: 0, through: 800, by: 100) {
            _ = hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms)))
        }
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1249))).outcome == nil)
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(1250))).outcome == .arrived)
    }

    @Test("Half a second without seeing the finger on the target starts the hold over",
          arguments: [false, true])
    func longDropout(missedFrames: Bool) {
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        for ms in stride(from: 0, through: 700, by: 100) {
            _ = hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms)))
        }
        if missedFrames {
            for ms in [800, 900, 1000, 1100] {
                #expect(hold.update(missed, at: epoch.advanced(by: .milliseconds(ms))).vector == .onTarget)
            }
            #expect(hold.update(missed, at: epoch.advanced(by: .milliseconds(1200))) == missed)
        }
        // The finger is back 500 ms after it was last seen, so the 1.25 s starts here.
        for ms in stride(from: 1200, through: 2400, by: 100) {
            #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(ms))).outcome == nil)
        }
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(2449))).outcome == nil)
        #expect(hold.update(sample(), at: epoch.advanced(by: .milliseconds(2450))).outcome == .arrived)
    }

    @Test("A finger that slides onto the next key while unseen never completes this one")
    func neighbourAfterDropout() {
        // The 8 and the 0 under it, from hand-labelled microwave-01.jpg.
        let eight = SurfaceMap.Button(label: "8", bounds: PanelRect(x: 0.405, y: 0.75, width: 0.2, height: 0.055),
                                      confidence: 1)
        let zero = SurfaceMap.Button(label: "0", bounds: PanelRect(x: 0.405, y: 0.835, width: 0.2, height: 0.065),
                                     confidence: 1)
        let pose = PanelPose(column0: SIMD4(1, 0, 0, 0), column1: SIMD4(0, 1, 0, 0),
                             column2: SIMD4(0, 0, 1, 0), column3: SIMD4(0, 0, 0, 1), confidence: 1)
        // On the 0 for 0.8 s, unseen for 0.4 s, then on the 8 for 2 s.
        let fingertips: [PanelPoint?] = Array(repeating: zero.bounds.center, count: 9)
            + Array(repeating: nil, count: 4) + Array(repeating: eight.bounds.center, count: 20)
        var hold = GuidanceArrivalHold()
        let epoch = ContinuousClock.now
        for (index, fingertip) in fingertips.enumerated() {
            let frame = TrackingFrame(timestamp: Date(), fingertip: fingertip, panel: pose,
                                      trackingQuality: fingertip == nil ? .degraded : .good)
            let state = hold.update(MockGuidance.state(for: frame, target: zero),
                                    at: epoch.advanced(by: .milliseconds(index * 100)))
            #expect(state.outcome != .arrived, "frame \(index)")
            if index >= 13 { #expect(state.vector != .onTarget, "frame \(index) is on the 8") }
        }
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

    @Test("A stall the hold rides out doesn't pause the hold's feedback")
    func briefStall() async {
        let haptics = HapticsExperienceEngine(onPulse: {})
        let engine = LiveFeedbackEngine(haptics: haptics)
        engine.setChannels(audio: false, voice: false, haptics: true)
        await engine.present(GuidanceState(timestamp: Date(), vector: .onTarget))
        let presented = ContinuousClock.now
        #expect(!engine.expireStaleGuidance(at: presented.advanced(by: .milliseconds(400))))
        #expect(haptics.isHoldingTarget && engine.instructionText == "Stop. Hold here.")
        #expect(engine.expireStaleGuidance(at: presented.advanced(by: GuidanceArrivalHold.maximumDropout)))
        #expect(!haptics.isRunning && engine.instructionText == "Guidance paused.")
        engine.stop()
    }
}
