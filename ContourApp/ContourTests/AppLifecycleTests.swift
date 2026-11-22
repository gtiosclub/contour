//
//  AppLifecycleTests.swift
//  ContourTests
//
//  The rules for what stops the camera screen. Whether the system really sends
//  these phases and notices at these moments only a phone can show.
//

import AVFoundation
import SwiftUI
import Testing
@testable import ContourApp

@Suite("App lifecycle")
struct AppLifecycleTests {

    @Test("Only the background stops the camera; inactive keeps whatever was running",
          arguments: [false, true])
    func scenePhases(wasRunning: Bool) {
        #expect(AppLifecycle.runs(in: .active, wasRunning: wasRunning))
        #expect(!AppLifecycle.runs(in: .background, wasRunning: wasRunning))
        #expect(AppLifecycle.runs(in: .inactive, wasRunning: wasRunning) == wasRunning)
    }

    @Test("Control Center during a plan, then back: the camera never stops")
    func controlCenter() {
        var running = AppLifecycle.runs(in: .active, wasRunning: false)
        for phase: ScenePhase in [.inactive, .active, .inactive, .active] {
            running = AppLifecycle.runs(in: phase, wasRunning: running)
            #expect(running)
        }
    }

    @Test("Locking the phone stops the camera, and unlocking starts it again")
    func lock() {
        var running = AppLifecycle.runs(in: .active, wasRunning: false)
        var history: [Bool] = []
        for phase: ScenePhase in [.inactive, .background, .inactive, .active] {
            running = AppLifecycle.runs(in: phase, wasRunning: running)
            history.append(running)
        }
        #expect(history == [true, false, false, true])
    }

    @Test("An interruption that begins takes the audio; its end doesn't")
    func interruptions() {
        let began: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        let ended: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue]
        #expect(AppLifecycle.audioWasTaken(began))
        #expect(AppLifecycle.audioWasTaken(ended) == false)
    }

    @Test("A notice without a readable type changes nothing")
    func unreadable() {
        #expect(!AppLifecycle.audioWasTaken(nil))
        #expect(!AppLifecycle.audioWasTaken([:]))
        #expect(!AppLifecycle.audioWasTaken([AVAudioSessionInterruptionTypeKey: "began"]))
        #expect(!AppLifecycle.audioWasTaken([AVAudioSessionInterruptionTypeKey: UInt(99)]))
    }

    @Test("Speech and the microphone share one setup the system accepts, and it comes back after guidance changes it")
    func audioSession() throws {
        #expect(AppAudioSession.options.contains(.defaultToSpeaker))
        #expect(AppAudioSession.options.contains(.mixWithOthers))
        #expect(!AppAudioSession.options.contains(.allowAirPlay))
        let session = AVAudioSession.sharedInstance()
        // What ContourFeedback's guidance cues set when they start.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try AppAudioSession.activate()
        #expect(session.category == .playAndRecord)
        #expect(session.mode == .default)
        #expect(session.categoryOptions == AppAudioSession.options)
        // Nothing changed it since, so this one leaves it alone.
        try AppAudioSession.activate()
        #expect(session.category == .playAndRecord)
    }
}
