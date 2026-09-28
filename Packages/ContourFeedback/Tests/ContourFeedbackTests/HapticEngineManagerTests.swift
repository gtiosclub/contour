//
//  HapticEngineManagerTests.swift
//  ContourFeedback — Experience / Haptics
//
//  What can be pinned without a Taptic Engine: input hygiene, the no-op contract
//  on unsupported hardware, and the frozen public surface. Feel is tested on a
//  phone through ContourApp's Haptics debug screen.
//
//  These run on macOS in CI, where `isSupported` is always false. The tests that
//  exercise start/stop therefore prove the no-crash path; the CoreHaptics path is
//  compiled by the ContourApp iOS build.
//

import Foundation
import Testing
@testable import ContourFeedback

@Suite("HapticEngineManager")
@MainActor
struct HapticEngineManagerTests {

    @Test("values outside 0...1 are clamped")
    func clamping() {
        #expect(HapticEngineManager.clamped(1.7) == 1)
        #expect(HapticEngineManager.clamped(-0.3) == 0)
        #expect(HapticEngineManager.clamped(0.42) == 0.42)
        #expect(HapticEngineManager.clamped(.infinity) == 1)
        #expect(HapticEngineManager.clamped(-.infinity) == 0)
    }

    @Test("NaN is rejected rather than clamped")
    func nanIsRejected() {
        #expect(HapticEngineManager.clamped(.nan) == nil)
    }

    @Test("update stores the clamped values, even while stopped")
    func updateClampsAndStores() {
        let subject = HapticEngineManager()
        subject.update(intensity: 2.0, sharpness: -1.0)
        #expect(subject.currentIntensity == 1)
        #expect(subject.currentSharpness == 0)

        subject.update(intensity: 0.25, sharpness: 0.75)
        #expect(subject.currentIntensity == 0.25)
        #expect(subject.currentSharpness == 0.75)
    }

    @Test("an update carrying NaN is ignored entirely")
    func nanUpdateIsIgnored() {
        let subject = HapticEngineManager()
        subject.update(intensity: 0.5, sharpness: 0.5)
        subject.update(intensity: .nan, sharpness: 0.9)
        subject.update(intensity: 0.9, sharpness: .nan)
        #expect(subject.currentIntensity == 0.5)
        #expect(subject.currentSharpness == 0.5)
    }

    @Test("start remembers intent so a system restart can resume it")
    func startRecordsIntent() throws {
        let subject = HapticEngineManager()
        #expect(subject.wantsRunning == false)
        try subject.start()
        #expect(subject.wantsRunning == true)
        subject.stop()
        #expect(subject.wantsRunning == false)
    }

    @Test("unsupported hardware makes every call a safe no-op")
    func unsupportedIsNoOp() throws {
        let subject = HapticEngineManager()
        try #require(subject.isSupported == false, "this test only means something without a Taptic Engine")

        #expect(subject.state == .unsupported)
        try subject.start()
        subject.update(intensity: 0.8, sharpness: 0.3)
        subject.tap(intensity: 1, sharpness: 1)
        subject.stop()
        subject.stop()
        #expect(subject.state == .unsupported, "no-op means the state never pretends to run")
        #expect(subject.resetCount == 0)
    }

    @Test("the frozen surface is exactly the four functions plus the read-only state")
    func frozenSurface() throws {
        // If this stops compiling, the public API changed. That needs the
        // Experience lead's OK and a Slack heads-up to every caller.
        let subject = HapticEngineManager()
        let _: () throws -> Void = subject.start
        let _: (Float, Float) -> Void = subject.update(intensity:sharpness:)
        let _: (Float, Float) -> Void = subject.tap(intensity:sharpness:)
        let _: () -> Void = subject.stop
        let _: Bool = subject.isSupported
        let _: HapticEngineManager.State = subject.state
        let _: Int = subject.resetCount
    }
}
