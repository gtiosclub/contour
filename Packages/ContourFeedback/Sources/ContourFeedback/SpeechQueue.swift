//
//  SpeechQueue.swift
//  ContourFeedback — Experience / Audio & Speech
//
//  Speech is a queue, not a function call. Everything that goes wrong with it
//  goes wrong because someone treated it as a function call.
//
//  `OutcomeAnnouncer` decides *what* to say; this decides *whether it gets said
//  now, later, or not at all*. Splitting them is what lets the Haptics and
//  Outcome lanes change their vocabulary without touching utterance scheduling.
//
//  ⚠️ THE CHANNEL IS ALREADY OCCUPIED.
//  The user is running VoiceOver. VoiceOver is already speaking — reading the
//  screen, announcing focus changes. Anything you say lands on top of it, and
//  the user cannot glance at the screen to recover what they missed. Speaking
//  more is almost never the fix.
//
//  ⚠️ SPEECH IS THE SLOWEST CHANNEL YOU HAVE.
//  "Left a bit, down a bit" takes about two seconds to say. The finger has moved
//  by the time it lands, so a correction spoken at camera rate is a correction
//  about the past. Continuous guidance belongs in haptics and audio; speech is
//  for things that are true for more than a moment — stage changes, outcomes,
//  and answers to a question the user asked.
//
//  `present(_:)` is called at camera rate, so every method here must start work
//  and return. Never await an utterance to finish.
//

import AVFoundation
import ContourCore
import Foundation

/// Owns the one AVSpeechSynthesizer and tracks which utterance is "current".
/// Callbacks for any other utterance (one we cut off) are ignored.
private final class SynthesizerDriver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var current: AVSpeechUtterance?

    /// Called when the *current* utterance ends. Never called for cut-off ones.
    var onFinished: (@Sendable () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Our own bookkeeping; `synthesizer.isSpeaking` lags behind `speak`/`stop`.
    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        lock.lock()
        let wasSpeaking = current != nil
        current = utterance               // replace BEFORE stopping, so the old
        lock.unlock()                     // cancel callback fails the identity check
        if wasSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
    }

    func stop() {
        lock.lock(); current = nil; lock.unlock()
        synthesizer.stopSpeaking(at: .immediate)   // harmless when idle
    }

    private func finishIfCurrent(_ utterance: AVSpeechUtterance) {
        lock.lock()
        guard utterance === current else { lock.unlock(); return }
        current = nil
        lock.unlock()
        onFinished?()
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        finishIfCurrent(u)
    }

    // Cut-off lines fail the identity check and are ignored. A cancel of the
    // *current* line (e.g. the system took the audio session) must still
    // advance the queue, or it would stall forever.
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        finishIfCurrent(u)
    }
}

public actor SpeechQueue {

    private struct Entry {
        let utterance: Utterance
        let enqueuedAt: ContinuousClock.Instant
    }

    private var entries: [Entry] = []
    private let clock = ContinuousClock()
    private let driver = SynthesizerDriver()

    public init() {
        driver.onFinished = { [weak self] in
            Task { await self?.pump() }
        }
    }

    public func enqueue(_ utterance: Utterance) async {
        if utterance.priority == .interrupting {
            entries.removeAll()           // drop everything queued behind it
        }
        entries.append(Entry(utterance: utterance, enqueuedAt: clock.now))
        pump()                            // starts work and returns; never awaits speech
    }

    public nonisolated func next(
        from queued: [(utterance: Utterance, waiting: Duration)],
        isSpeaking: Bool
    ) -> Utterance? {
        let live = queued.filter { !Self.isExpired($0.utterance, waiting: $0.waiting) }

        // Interrupting plays now, even mid-speech. If several, the newest wins.
        if let urgent = live.last(where: { $0.utterance.priority == .interrupting }) {
            return urgent.utterance
        }
        if isSpeaking { return nil }      // everything else waits its turn

        // Highest priority wins, so low loses to normal; oldest first within a tier.
        guard let top = live.map({ $0.utterance.priority }).max() else { return nil }
        return live.first(where: { $0.utterance.priority == top })?.utterance
    }

    public func stop() async {
        entries.removeAll()
        driver.stop()
    }

    // MARK: - Internals

    private static func isExpired(_ utterance: Utterance, waiting: Duration) -> Bool {
        guard let limit = utterance.expiresAfter else { return false }
        return waiting > limit
    }

    private func pump() {
        let now = clock.now
        entries.removeAll { Self.isExpired($0.utterance, waiting: now - $0.enqueuedAt) }

        // "Drop it if something outranks it": low doesn't wait behind real speech.
        if entries.contains(where: { $0.utterance.priority > .low }) {
            entries.removeAll { $0.utterance.priority == .low }
        }

        let queued = entries.map { (utterance: $0.utterance, waiting: now - $0.enqueuedAt) }
        guard let chosen = next(from: queued, isSpeaking: driver.isSpeaking),
              let index = entries.firstIndex(where: { $0.utterance == chosen })
        else { return }

        entries.remove(at: index)
        driver.speak(chosen.text)         // one line at a time; stops the old one if needed
    }
}
