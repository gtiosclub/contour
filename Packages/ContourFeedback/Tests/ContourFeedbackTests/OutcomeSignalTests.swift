//
//  OutcomeSignalTests.swift
//  ContourFeedbackTests — Experience / Outcome Signals & Harness
//
//  Pins the four outcome signals (#55) and their earcons (#115): every outcome
//  is told apart on every channel, notFound is not lowConfidence on several
//  dimensions at once, and the earcons render without clicks. Nothing here
//  plays a sound.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

@Suite("Outcome signals")
struct OutcomeSignalTests {

    private let announcer = OutcomeAnnouncer(player: HapticPlayer())

    private var presentations: [OutcomeSignal: OutcomePresentation] {
        Dictionary(uniqueKeysWithValues: OutcomeSignal.allCases.map { ($0, announcer.presentation(for: $0)) })
    }

    // MARK: Every outcome, every channel

    @Test("all four presentations differ pairwise in haptics, earcon and words")
    func pairwiseDistinct() throws {
        let all = OutcomeSignal.allCases
        for (index, first) in all.enumerated() {
            for second in all.dropFirst(index + 1) {
                let a = try #require(presentations[first]), b = try #require(presentations[second])
                #expect(a.haptics != b.haptics, "\(first) and \(second) feel the same")
                #expect(a.earcon != b.earcon, "\(first) and \(second) sound the same")
                #expect(a.utterance != b.utterance, "\(first) and \(second) say the same")
                #expect(a.audio != b.audio, "\(first) and \(second) share a headline cue")
            }
        }
    }

    @Test("every outcome has haptics, an earcon, a headline cue and words")
    func nothingIsMissing() {
        for (outcome, presentation) in presentations {
            #expect(!presentation.haptics.isEmpty, "\(outcome)")
            #expect(presentation.earcon?.notes.isEmpty == false, "\(outcome)")
            #expect(presentation.audio != nil, "\(outcome)")
            #expect(presentation.utterance?.isEmpty == false, "\(outcome)")
        }
    }

    @Test("the headline cue is the earcon's first note")
    func headlineIsFirstNote() throws {
        for presentation in presentations.values {
            let first = try #require(presentation.earcon?.notes.first)
            #expect(presentation.audio == AudioCue(pan: 0, pitch: first.frequency, gain: first.gain))
        }
    }

    // MARK: notFound is not lowConfidence

    @Test("notFound and lowConfidence sound different in register, rhythm and contour")
    func notFoundDoesNotSoundLikeLowConfidence() throws {
        let notFound = OutcomeAnnouncer.earcon(for: .notFound)
        let unsure = OutcomeAnnouncer.earcon(for: .lowConfidence)

        let register = Self.meanPitch(unsure) / Self.meanPitch(notFound) >= 1.5
        let rhythm = notFound.notes.count != unsure.notes.count
            && Self.meanNoteLength(notFound) / Self.meanNoteLength(unsure) >= 2
        let contour = Self.directionChanges(notFound) != Self.directionChanges(unsure)

        let differences = [register, rhythm, contour].filter { $0 }.count
        #expect(differences >= 2, "register \(register), rhythm \(rhythm), contour \(contour)")
        #expect(register && rhythm && contour, "today they differ on all three; keep it that way")
    }

    @Test("notFound and lowConfidence feel different in count and touch")
    func notFoundDoesNotFeelLikeLowConfidence() throws {
        let notFound = try #require(presentations[.notFound]).haptics
        let unsure = try #require(presentations[.lowConfidence]).haptics
        #expect(notFound.count != unsure.count)
        #expect(notFound.map(\.sharpness).max()! < unsure.map(\.sharpness).min()!, "heavy and dull vs light and crisp")
        #expect(notFound.map(\.intensity).min()! > unsure.map(\.intensity).max()!)
    }

    // MARK: Each earcon's shape

    @Test("arrived rises; lostTracking falls and fades")
    func contours() throws {
        let arrived = OutcomeAnnouncer.earcon(for: .arrived).notes
        #expect(try #require(arrived.last).frequency > (try #require(arrived.first)).frequency)

        let lost = try #require(OutcomeAnnouncer.earcon(for: .lostTracking).notes.first)
        #expect(lost.endFrequency < lost.frequency)
        #expect(lost.endGain < lost.gain)
    }

    @Test("every earcon is short enough not to hold up the words")
    func earconsAreShort() {
        for outcome in OutcomeSignal.allCases {
            let duration = OutcomeAnnouncer.earcon(for: outcome).duration
            #expect(duration > .zero && duration <= .milliseconds(600), "\(outcome) is \(duration)")
        }
    }

    @Test("an earcon renders mono samples that start and end silent and never click",
          arguments: OutcomeSignal.allCases)
    func earconRendersCleanly(outcome: OutcomeSignal) throws {
        let earcon = OutcomeAnnouncer.earcon(for: outcome)
        let samples = earcon.samples(sampleRate: 48_000)
        let expected = Int((Earcon.seconds(earcon.duration) * 48_000).rounded(.up))
        #expect(samples.count == expected)

        let first = try #require(samples.first), last = try #require(samples.last)
        #expect(abs(first) < 0.01 && abs(last) < 0.01, "a hard edge clicks")
        #expect(samples.allSatisfy { abs($0) <= 1 })
        #expect((samples.map { abs($0) }.max() ?? 0) > 0.1, "it has to be audible")

        let steps = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
        #expect((steps.max() ?? 0) < 0.35, "a jump between samples is a click")
    }

    // MARK: Speech routing

    @Test("an interrupting outcome's words cut in; the rest wait their turn")
    func speechPriorityFollowsInterrupts() throws {
        var presentation = try #require(presentations[.arrived])
        let urgent = try #require(OutcomeAnnouncer.utterance(for: presentation, withEarcon: false))
        #expect(urgent.priority == .interrupting)
        #expect(urgent.text == presentation.utterance)
        #expect(urgent.expiresAfter != nil, "an outcome line must not land in the next session")

        presentation.interrupts = false
        #expect(OutcomeAnnouncer.utterance(for: presentation, withEarcon: false)?.priority == .normal)

        presentation.utterance = nil
        #expect(OutcomeAnnouncer.utterance(for: presentation, withEarcon: false) == nil)
    }

    @Test("the words wait for the earcon, and only when one actually played")
    func speechWaitsForTheEarcon() throws {
        let presentation = try #require(presentations[.lostTracking])
        let earcon = try #require(presentation.earcon)
        #expect(OutcomeAnnouncer.utterance(for: presentation, withEarcon: true)?.leadIn == earcon.duration)
        #expect(OutcomeAnnouncer.utterance(for: presentation, withEarcon: false)?.leadIn == .zero)
    }

    @Test("announcing with haptics only returns promptly and plays no sound")
    func hapticsOnlyAnnounce() async {
        let clock = ContinuousClock()
        for outcome in OutcomeSignal.allCases {
            let elapsed = await clock.measure { await announcer.announce(outcome) }
            #expect(elapsed < .milliseconds(50))
        }
    }

    // MARK: Helpers

    private static func meanPitch(_ earcon: Earcon) -> Double {
        let pitches = earcon.notes.map { ($0.frequency + $0.endFrequency) / 2 }
        return pitches.reduce(0, +) / Double(pitches.count)
    }

    private static func meanNoteLength(_ earcon: Earcon) -> Double {
        earcon.notes.map { Earcon.seconds($0.duration) }.reduce(0, +) / Double(earcon.notes.count)
    }

    /// How many times the melody turns around (up then down, or down then up).
    private static func directionChanges(_ earcon: Earcon) -> Int {
        let pitches = earcon.notes.flatMap { [$0.frequency, $0.endFrequency] }
        let moves = zip(pitches, pitches.dropFirst()).compactMap { a, b -> Int? in
            a == b ? nil : (b > a ? 1 : -1)
        }
        return zip(moves, moves.dropFirst()).filter { $0 != $1 }.count
    }
}
