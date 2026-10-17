//
//  DirectionalAudioTests.swift
//  ContourFeedbackTests — Experience / Audio & Speech
//
//  Created by Asutosh Mishra on 10/8/26.
//
//  Pins the cue, not the sound: pan from dx, pitch from -dy (the axis trap),
//  gain from distance, and a loop buffer that cannot click. Nothing here plays
//  audio.
//

import AVFoundation
import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

@Suite("DirectionalAudio")
struct DirectionalAudioTests {

    let audio = DirectionalAudio()

    private func cue(_ dx: Double, _ dy: Double) -> AudioCue {
        audio.cue(for: PanelVector(dx: dx, dy: dy))
    }

    // MARK: Pan

    @Test("a target to the left pans left, to the right pans right")
    func panFollowsDx() {
        #expect(cue(-1, 0).pan < 0)
        #expect(cue(1, 0).pan > 0)
        #expect(abs(cue(0, 0).pan) < 1e-9)
    }

    @Test("pan is hard at the extremes")
    func panIsHardAtExtremes() {
        #expect(abs(cue(-1, 0).pan - -1) < 1e-9)
        #expect(abs(cue(1, 0).pan - 1) < 1e-9)
    }

    // MARK: Pitch (the axis trap)

    @Test("+dy is down: a target ABOVE the finger (negative dy) sounds HIGHER")
    func targetAboveFingerGivesHigherPitch() {
        #expect(cue(0, -1).pitch > cue(0, 1).pitch)
        #expect(cue(0, -1).pitch > cue(0, 0).pitch)
        #expect(cue(0, 0).pitch > cue(0, 1).pitch)
    }

    @Test("straight up is the top of the range, straight down the bottom")
    func pitchRangeEndpoints() {
        #expect(abs(cue(0, -1).pitch - DirectionalAudio.highPitch) < 1e-6)
        #expect(abs(cue(0, 1).pitch - DirectionalAudio.lowPitch) < 1e-6)
    }

    @Test("pitch rises steadily as the target moves up")
    func pitchIsMonotonicInUp() {
        let pitches = stride(from: 1.0, through: -1.0, by: -0.1).map { cue(0, $0).pitch }
        #expect(pitches == pitches.sorted())
    }

    // MARK: Independence and robustness

    @Test("pan and pitch are independent")
    func panAndPitchAreIndependent() {
        #expect(abs(cue(0.6, -0.8).pan - cue(0.6, 0.8).pan) < 1e-9)
        #expect(abs(cue(-0.6, -0.8).pitch - cue(0.6, -0.8).pitch) < 1e-9)
    }

    @Test("non-unit, NaN and infinite directions stay in range")
    func nonFiniteInputsStayInRange() {
        for subject in [cue(5, -5), cue(-5, 5), cue(.nan, .nan), cue(.infinity, -.infinity)] {
            #expect((-1.0...1.0).contains(subject.pan))
            #expect((DirectionalAudio.lowPitch...DirectionalAudio.highPitch).contains(subject.pitch))
            #expect(subject.pitch.isFinite)
        }
        #expect(abs(cue(.nan, .nan).pan) < 1e-9, "NaN is centred, not hard left")
    }

    // MARK: Gain (closer is louder)

    @Test("farDistance is in normalizedDistance units: 1 is the far corner")
    func farDistanceDefaultsToOne() {
        #expect(audio.farDistance == 1)
        #expect(abs(audio.gain(forDistance: 1) - audio.minimumGain) < 1e-9)
        #expect(audio.gain(forDistance: 0.5) > audio.minimumGain, "mid-panel must not already be at the floor")
    }

    @Test("gain never goes up as distance goes up")
    func gainIsMonotonic() {
        let gains = stride(from: -0.5, through: 2.5, by: 0.01).map { audio.gain(forDistance: $0) }
        for (nearer, farther) in zip(gains, gains.dropFirst()) {
            #expect(farther <= nearer)
        }
        #expect(audio.gain(forDistance: 0.1) > audio.gain(forDistance: 0.5))
        #expect(audio.gain(forDistance: 0.5) > audio.gain(forDistance: 0.9))
    }

    @Test("gain is 1 on the target and never below the floor, even off the panel or NaN")
    func gainBounds() {
        #expect(abs(audio.gain(forDistance: 0) - 1) < 1e-9)
        #expect(abs(audio.gain(forDistance: -5) - 1) < 1e-9)
        #expect(abs(audio.gain(forDistance: 2.5) - audio.minimumGain) < 1e-9)
        #expect(abs(audio.gain(forDistance: .nan) - audio.minimumGain) < 1e-9)
        #expect(abs(audio.gain(forDistance: .infinity) - audio.minimumGain) < 1e-9)
    }

    @Test("a nonsense farDistance falls back instead of dividing by zero")
    func badFarDistanceFallsBack() {
        for far in [0, -3, Double.nan] {
            let subject = DirectionalAudio(farDistance: far)
            #expect(subject.farDistance == 1)
            #expect(subject.gain(forDistance: 0.5).isFinite)
        }
    }

    // MARK: The state adapter

    @Test("a guiding state plays its cue; no vector or a terminal state is silent")
    func stateAdapter() throws {
        let at = Date(timeIntervalSince1970: 0)
        let up = GuidanceVector(direction: PanelVector(dx: 0, dy: -1), normalizedDistance: 0.3)
        let cue = try #require(audio.cue(for: GuidanceState(timestamp: at, vector: up)))
        #expect(cue == audio.cue(for: up.direction, distance: 0.3))
        #expect(audio.cue(for: GuidanceState(timestamp: at, vector: nil)) == nil)
        #expect(audio.cue(for: GuidanceState(timestamp: at, vector: up, outcome: .arrived)) == nil)
    }

    // MARK: Loop buffer (no clicks)

    @Test("the loop holds a whole number of cycles, with or without the harmonic")
    func bufferHoldsWholeNumberOfCycles() {
        let cycles = Double(LoopTone.frameCount) * LoopTone.frequency / LoopTone.sampleRate
        #expect(abs(cycles - cycles.rounded()) < 1e-9)
        let harmonicCycles = cycles * 2
        #expect(abs(harmonicCycles - harmonicCycles.rounded()) < 1e-9)
    }

    @Test("the loop point is continuous and the buffer is mono", arguments: [false, true])
    func loopPointIsContinuousAndMono(harmonic: Bool) throws {
        let buffer = LoopTone.makeBuffer(harmonic: harmonic)
        #expect(buffer.format.channelCount == 1, "stereo would make pan do nothing")
        let samples = try #require(buffer.floatChannelData?[0])
        let last = Int(buffer.frameLength) - 1
        let wrapStep = abs(samples[0] - samples[last])
        let normalStep = abs(samples[1] - samples[0])
        #expect(abs(wrapStep - normalStep) < 1e-4, "the wrap looks like any other sample step")
        let peak = (0...last).map { abs(samples[$0]) }.max() ?? 0
        #expect(peak <= 0.5 + 1e-6, "the harmonic must not push the level up")
    }

    // MARK: Rendering stays safe

    @MainActor
    @Test("retargeting clamps and ignores non-finite values without starting anything")
    func retargetClamps() {
        let tone = ToneEngine(harmonic: false)
        tone.retarget(pan: 3, rate: 100, gain: -1)
        #expect(tone.target == ToneEngine.Mix(pan: 1, rate: 4, gain: 0))
        tone.retarget(pan: .nan, rate: .infinity, gain: .nan)
        #expect(tone.target == ToneEngine.Mix(pan: 1, rate: 4, gain: 0))
        #expect(!tone.wantsTone && !tone.isRunning)
    }

    @Test("stop when idle is safe")
    func stopWhenIdleIsSafe() async {
        let quiet = DirectionalAudio(tone: ToneEngine(harmonic: true))
        await quiet.stop()
        await quiet.stop()
    }
}
