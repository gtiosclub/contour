//
//  DirectionalAudioTests.swift
//  ContourFeedback
//
//  Created by Asutosh Mishra on 10/8/26.
//

import AVFoundation
import XCTest
import ContourCore
@testable import ContourFeedback

final class DirectionalAudioTests: XCTestCase {
    let audio = DirectionalAudio()

    // ⚠️ assumes PanelVector(dx:dy:)
    private func cue(_ dx: Double, _ dy: Double) -> AudioCue {
        audio.cue(for: PanelVector(dx: dx, dy: dy))
    }

    // MARK: Pan
    func testTargetToTheLeftPansLeft()  { XCTAssertLessThan(cue(-1, 0).pan, 0) }
    func testTargetToTheRightPansRight() { XCTAssertGreaterThan(cue(1, 0).pan, 0) }
    func testCenteredIsCentered()        { XCTAssertEqual(cue(0, 0).pan, 0, accuracy: 1e-9) }
    func testPanIsHardAtExtremes() {
        XCTAssertEqual(cue(-1, 0).pan, -1, accuracy: 1e-9)
        XCTAssertEqual(cue(1, 0).pan, 1, accuracy: 1e-9)
    }

    // MARK: Pitch (the axis trap)
    func testTargetAboveFingerGivesHigherPitch() {
        // dy = -1 means "move UP the panel"
        XCTAssertGreaterThan(cue(0, -1).pitch, cue(0, 1).pitch)
    }
    func testAboveIsHigherThanLevelAndLevelHigherThanBelow() {
        XCTAssertGreaterThan(cue(0, -1).pitch, cue(0, 0).pitch)
        XCTAssertGreaterThan(cue(0, 0).pitch, cue(0, 1).pitch)
    }
    func testPitchRangeEndpoints() {
        XCTAssertEqual(cue(0, -1).pitch, DirectionalAudio.highPitch, accuracy: 1e-6)
        XCTAssertEqual(cue(0, 1).pitch, DirectionalAudio.lowPitch, accuracy: 1e-6)
    }
    func testPitchIsMonotonicInUp() {
        let pitches = stride(from: 1.0, through: -1.0, by: -0.1).map { cue(0, $0).pitch }
        XCTAssertEqual(pitches, pitches.sorted())
    }

    // MARK: Independence and robustness
    func testPanAndPitchAreIndependent() {
        XCTAssertEqual(cue(0.6, -0.8).pan, cue(0.6, 0.8).pan, accuracy: 1e-9)
        XCTAssertEqual(cue(-0.6, -0.8).pitch, cue(0.6, -0.8).pitch, accuracy: 1e-9)
    }
    func testNonUnitAndNonFiniteInputsStayInRange() {
        for v in [cue(5, -5), cue(-5, 5), cue(.nan, .nan), cue(.infinity, -.infinity)] {
            XCTAssertTrue((-1.0...1.0).contains(v.pan))
            XCTAssertTrue((DirectionalAudio.lowPitch...DirectionalAudio.highPitch).contains(v.pitch))
        }
    }

    // MARK: Gain (closer is louder)
    func testCloserIsLouder() {
        XCTAssertGreaterThan(audio.gain(forDistance: 10), audio.gain(forDistance: 100))
        XCTAssertGreaterThan(audio.gain(forDistance: 100), audio.gain(forDistance: 250))
    }
    func testGainBounds() {
        XCTAssertEqual(audio.gain(forDistance: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(audio.gain(forDistance: 1e9), audio.minimumGain, accuracy: 1e-9)
        XCTAssertEqual(audio.gain(forDistance: -5), 1, accuracy: 1e-9)
        XCTAssertEqual(audio.gain(forDistance: .nan), audio.minimumGain, accuracy: 1e-9)
    }

    // MARK: Loop buffer (no clicks)
    func testBufferHoldsWholeNumberOfCycles() {
        let cycles = Double(LoopTone.frameCount) * LoopTone.frequency / LoopTone.sampleRate
        XCTAssertEqual(cycles, cycles.rounded(), accuracy: 1e-9)
    }
    func testLoopPointIsContinuousAndMono() {
        let buf = LoopTone.makeBuffer()
        XCTAssertEqual(buf.format.channelCount, 1)
        let s = buf.floatChannelData![0]
        let last = Int(buf.frameLength) - 1
        let wrapStep = abs(s[0] - s[last])
        let normalStep = abs(s[1] - s[0])
        XCTAssertEqual(wrapStep, normalStep, accuracy: 1e-4)   // the wrap looks like any other sample step
    }

    func testStopWhenIdleIsSafe() async {
        await audio.stop()
        await audio.stop()
    }
}
