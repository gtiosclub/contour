//
//  SpeechQueueTests.swift
//  ContourFeedbackTests — Experience / Audio & Speech
//
//  Pins the scheduling rules in `next(from:isSpeaking:)`, which is pure: which
//  line is said next, given what is queued, how long each has waited, and
//  whether something is already being said. Nothing here speaks aloud.
//

import Foundation
import Testing
@testable import ContourFeedback

@Suite("SpeechQueue")
struct SpeechQueueTests {

    private let queue = SpeechQueue()

    private func line(
        _ text: String,
        _ priority: SpeechPriority,
        expires: Duration? = nil
    ) -> Utterance {
        Utterance(text: text, priority: priority, expiresAfter: expires)
    }

    private func next(
        _ queued: [(Utterance, Duration)],
        speaking: Bool = false
    ) -> Utterance? {
        queue.next(from: queued.map { (utterance: $0.0, waiting: $0.1) }, isSpeaking: speaking)
    }

    @Test("nothing queued means nothing to say")
    func emptyIsNil() {
        #expect(next([]) == nil)
        #expect(next([], speaking: true) == nil)
    }

    @Test("an expired line is dropped, and the live one behind it is said")
    func expiredIsDropped() {
        let stale = line("left a bit", .normal, expires: .seconds(1))
        let fresh = line("target found", .low)
        #expect(next([(stale, .seconds(2))]) == nil)
        #expect(next([(stale, .seconds(2)), (fresh, .seconds(2))]) == fresh)
    }

    @Test("a line at exactly its expiry is still said; one past it is not")
    func expiryBoundary() {
        let subject = line("left a bit", .normal, expires: .seconds(1))
        #expect(next([(subject, .seconds(1))]) == subject)
        #expect(next([(subject, .milliseconds(1_001))]) == nil)
    }

    @Test("an expired interrupting line does not cut in")
    func expiredInterruptingIsDropped() {
        let stale = line("you're on it", .interrupting, expires: .seconds(1))
        #expect(next([(stale, .seconds(3))], speaking: true) == nil)
    }

    @Test("interrupting wins, and cuts in even while something is being said")
    func interruptingCutsIn() {
        let normal = line("target found", .normal)
        let urgent = line("you're on it", .interrupting)
        #expect(next([(normal, .seconds(3)), (urgent, .zero)]) == urgent)
        #expect(next([(normal, .seconds(3)), (urgent, .zero)], speaking: true) == urgent)
    }

    @Test("of several interrupting lines, the newest wins")
    func newestInterruptingWins() {
        let older = line("lost the panel", .interrupting)
        let newer = line("you're on it", .interrupting)
        #expect(next([(older, .seconds(1)), (newer, .zero)]) == newer)
    }

    @Test("low loses to normal, whichever was queued first")
    func lowLosesToNormal() {
        let low = line("warmer", .low)
        let normal = line("target found", .normal)
        #expect(next([(low, .seconds(5)), (normal, .zero)]) == normal)
        #expect(next([(normal, .zero), (low, .seconds(5))]) == normal)
    }

    @Test("within a tier, first in is first out")
    func fifoWithinATier() {
        let first = line("first", .normal)
        let second = line("second", .normal)
        #expect(next([(first, .seconds(3)), (second, .seconds(1))]) == first)

        let lowFirst = line("low first", .low)
        let lowSecond = line("low second", .low)
        #expect(next([(lowFirst, .seconds(3)), (lowSecond, .seconds(1))]) == lowFirst)
    }

    @Test("while speaking, nothing short of interrupting is started")
    func nilWhileSpeakingWithNothingUrgent() {
        let normal = line("target found", .normal)
        let low = line("warmer", .low)
        #expect(next([(normal, .zero), (low, .zero)], speaking: true) == nil)
    }

    @Test("stop is safe when idle, twice over, and leaves the channel silent")
    func stopWhenIdleIsSafe() async {
        await queue.stop()
        await queue.stop()
        #expect(await queue.isSpeaking == false)
    }

    @Test("a new listener hears what the channel is doing right away")
    func activityStartsWithCurrentState() async {
        var first: SpeechActivity?
        for await activity in queue.activityUpdates() {
            first = activity
            break
        }
        #expect(first == .silent)
    }

    @Test("speaking is any priority; silent is not speaking")
    func activityIsSpeaking() {
        #expect(!SpeechActivity.silent.isSpeaking)
        for priority in SpeechPriority.allCases {
            #expect(SpeechActivity.speaking(priority).isSpeaking)
        }
    }
}
