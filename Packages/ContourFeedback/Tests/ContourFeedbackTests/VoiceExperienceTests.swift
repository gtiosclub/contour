import AVFoundation
import Foundation
import Testing
@testable import ContourFeedback

@Test("Direction changes replace speech immediately; wording changes wait")
func voiceDirectionPriority() {
    var policy = ExperienceVoicePolicy()
    #expect(policy.update(.direction(.right, near: false), distance: 1, at: 0, isSpeaking: false) == [.moveRight])
    #expect(policy.update(.direction(.right, near: false), distance: 0.8, at: 0.2, isSpeaking: true) == nil)
    #expect(policy.update(.direction(.right, near: true), distance: 0.2, at: 0.3, isSpeaking: true) == nil)
    #expect(policy.update(.direction(.down, near: true), distance: 0.2, at: 0.4, isSpeaking: true) == [.nowDown])
    #expect(policy.update(.direction(.up, near: true), distance: 0.2, at: 0.6, isSpeaking: true) == [.nowUp])
    #expect(policy.update(.direction(.up, near: true), distance: 0.19, at: 1, isSpeaking: false) == nil)
}

@Test("Slow approach and stationary positions never trigger repeated reminders")
func voiceReminderTiming() {
    var policy = ExperienceVoicePolicy()
    #expect(policy.update(.direction(.left, near: true), distance: 0.24, at: 0, isSpeaking: false) == [.nearLeft])
    for second in 1...30 {
        #expect(policy.update(.direction(.left, near: true), distance: 0.24 - Double(second) * 0.001,
                              at: Double(second), isSpeaking: false) == nil)
    }
    #expect(policy.update(.direction(.left, near: true), distance: 0.21, at: 60, isSpeaking: false) == nil)
}

@Test("Retreat reminders are two seconds apart and require renewed movement away")
func voiceRetreatReminders() {
    var policy = ExperienceVoicePolicy()
    _ = policy.update(.direction(.left, near: true), distance: 0.2, at: 0, isSpeaking: false)
    #expect(policy.update(.direction(.left, near: true), distance: 0.23, at: 1, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.left, near: true), distance: 0.24, at: 2, isSpeaking: false) == [.nearLeft])
    #expect(policy.update(.direction(.left, near: true), distance: 0.27, at: 3, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.left, near: true), distance: 0.28, at: 4, isSpeaking: true) == nil)
    #expect(policy.update(.direction(.left, near: true), distance: 0.29, at: 4.1, isSpeaking: false) == [.nearLeft])
    #expect(policy.update(.direction(.left, near: true), distance: 0.29, at: 10, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.left, near: true), distance: 0.295, at: 11, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.left, near: true), distance: 0.28, at: 12, isSpeaking: false) == nil)
}

@Test("Retreat is measured from recent progress, without stale reminders on recovery")
func voiceRetreatAfterProgress() {
    var policy = ExperienceVoicePolicy()
    _ = policy.update(.direction(.right, near: false), distance: 0.8, at: 0, isSpeaking: false)
    _ = policy.update(.direction(.right, near: false), distance: 0.4, at: 1, isSpeaking: false)
    #expect(policy.update(.direction(.right, near: false), distance: 0.45, at: 1.5, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.right, near: false), distance: 0.44, at: 3, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.right, near: false), distance: 0.44, at: 5, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.right, near: false), distance: 0.46, at: 6, isSpeaking: false) == [.moveRight])
}

@Test("Arrival and loss interrupt once, with fresh direction after resumption")
func voiceArrivalAndLoss() {
    var policy = ExperienceVoicePolicy()
    _ = policy.update(.direction(.right, near: false), distance: 1, at: 0, isSpeaking: false)
    #expect(policy.update(.arrived, distance: 0, at: 0.1, isSpeaking: true) == [.stop, .reached])
    #expect(policy.update(.arrived, distance: 0, at: 20, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.up, near: true), distance: 0.1, at: 21, isSpeaking: true) == [.nearUp])
    #expect(policy.update(.paused, distance: .nan, at: 22, isSpeaking: true) == [.paused])
    #expect(policy.update(.paused, distance: .nan, at: 30, isSpeaking: false) == nil)
    #expect(policy.update(.direction(.down, near: false), distance: 1, at: 31, isSpeaking: false) == [.moveDown])
    #expect(policy.update(.arrived, distance: 0, at: 30, isSpeaking: false) == nil)
}

@Test("A deferred near phrase is spoken once after the current sentence")
func voiceNearTransition() {
    var policy = ExperienceVoicePolicy()
    _ = policy.update(.direction(.up, near: false), distance: 0.5, at: 0, isSpeaking: false)
    #expect(policy.update(.direction(.up, near: true), distance: 0.2, at: 0.1, isSpeaking: true) == nil)
    #expect(policy.update(.direction(.up, near: true), distance: 0.2, at: 1, isSpeaking: false) == [.nearUp])
    #expect(policy.update(.direction(.up, near: true), distance: 0.2, at: 2, isSpeaking: false) == nil)
}

@Test("Every vocabulary clip is bundled, decodable, audible, and unclipped")
// File decoding and sample scans must not block main-actor feedback timing tests.
@concurrent
func voiceResources() async throws {
    for cue in ExperienceVoiceCue.allCases {
        let url = try #require(await VoiceExperienceEngine.resourceURL(for: cue))
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(duration > 0.15 && duration < 4, "\(cue.rawValue): unreasonable duration")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        #expect(samples.allSatisfy { $0.isFinite && abs($0) < 0.99 })
        #expect(samples.contains { abs($0) > 0.05 }, "\(cue.rawValue): silent recording")
        #expect(abs(samples.first ?? 1) < 0.01 && abs(samples.last ?? 1) < 0.01)
    }
}
