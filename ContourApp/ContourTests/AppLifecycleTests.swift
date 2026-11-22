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
}
