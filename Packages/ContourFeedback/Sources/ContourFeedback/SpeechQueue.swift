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
//  OTHERS CAN LISTEN
//  `activityUpdates()` says when a line starts and stops, and how urgent it is,
//  so the directional tone can duck under the words. Interruptions and route
//  changes arrive through AudioSessionConfig.events(); this never touches the
//  session category itself.
//

import AVFoundation
import ContourCore
import Foundation

/// How an utterance competes with whatever is already being spoken.
public enum SpeechPriority: Int, Hashable, Sendable, CaseIterable, Comparable {

    /// Say it if nothing else is queued; drop it if something outranks it.
    /// Progress chatter belongs here, if it belongs anywhere.
    case low

    /// Say it in turn. Stage changes and announcements the flow owes the user.
    case normal

    /// Say it now, and drop whatever is queued behind it. `arrived` and
    /// `lostTracking` are the cases this exists for — a stale "warmer" landing
    /// after the user has already arrived is worse than silence.
    case interrupting

    public static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One thing to say, and how badly it wants to be said.
public struct Utterance: Hashable, Sendable {

    /// The text to speak. Written to be *heard*, not read: no abbreviations, no
    /// punctuation the synthesiser will mispronounce, no leading "OK, so".
    public var text: String

    /// How it competes with what is already speaking.
    public var priority: SpeechPriority

    /// Drop this utterance if it has not been spoken within this long.
    ///
    /// The point of the whole type. A correction that is four seconds stale is
    /// not just useless, it is actively misleading — it sends a finger somewhere
    /// the target no longer is. `nil` means it stays valid indefinitely, which
    /// is right for outcomes and wrong for almost everything else.
    public var expiresAfter: Duration?

    /// Silence before the words once the line starts, so an earcon can finish
    /// before the first word lands on top of it. Zero for most lines.
    public var leadIn: Duration

    public init(
        text: String,
        priority: SpeechPriority,
        expiresAfter: Duration? = nil,
        leadIn: Duration = .zero
    ) {
        self.text = text
        self.priority = priority
        self.expiresAfter = expiresAfter
        self.leadIn = leadIn
    }
}

/// What the speech channel is doing right now, for anything that has to get out
/// of its way — the directional tone ducks under it.
public enum SpeechActivity: Hashable, Sendable {

    /// Nothing is being said.
    case silent

    /// A line is being said, at this priority.
    case speaking(SpeechPriority)

    public var isSpeaking: Bool { self != .silent }
}

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

    func speak(_ text: String, leadIn: Duration = .zero) {
        let utterance = AVSpeechUtterance(string: text)
        let parts = leadIn.components
        utterance.preUtteranceDelay = max(0, Double(parts.seconds) + Double(parts.attoseconds) * 1e-18)
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

    /// Pick up a line the system paused (an interruption, a route change).
    func resumeIfPaused() {
        if synthesizer.isPaused { synthesizer.continueSpeaking() }
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
    private var activity: SpeechActivity = .silent
    private var listeners: [UUID: AsyncStream<SpeechActivity>.Continuation] = [:]

    public init() {
        driver.onFinished = { [weak self] in
            Task { await self?.finished() }
        }
        Task { [weak self] in
            for await event in await AudioSessionConfig.events() {
                guard let self else { return }   // the queue is gone: stop listening
                await self.handle(event)
            }
        }
    }

    deinit {
        for listener in listeners.values { listener.finish() }
    }

    /// Whether a line is being said right now.
    public var isSpeaking: Bool { activity.isSpeaking }

    /// Every change in what the speech channel is doing, starting with what it
    /// is doing now. Each call returns its own stream; it finishes when the
    /// queue goes away. Only the latest value is buffered, so a slow listener
    /// never acts on a stale one.
    ///
    /// Back-to-back lines report one continuous `.speaking`, not a blip of
    /// `.silent` in between, so a ducked tone does not pop up between them.
    public nonisolated func activityUpdates() -> AsyncStream<SpeechActivity> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SpeechActivity.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        Task { await self.addListener(continuation, id: id) }
        return stream
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

    /// Drop everything queued and cut off the line being said. Safe when idle.
    public func stop() async {
        entries.removeAll()
        driver.stop()
        setActivity(.silent)
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
        driver.speak(chosen.text, leadIn: chosen.leadIn)   // one line at a time; stops the old one if needed
        setActivity(.speaking(chosen.priority))
    }

    /// The current line ended. Start the next one before reporting silence, so
    /// listeners see one unbroken `.speaking` across back-to-back lines.
    private func finished() {
        pump()
        if !driver.isSpeaking { setActivity(.silent) }
    }

    private func handle(_ event: AudioSessionConfig.Event) {
        switch event {
        case .interruptionBegan:
            break                         // the system pauses or cancels the line itself
        case .interruptionEnded, .routeChanged:
            driver.resumeIfPaused()
            pump()
        }
    }

    private func setActivity(_ new: SpeechActivity) {
        guard new != activity else { return }
        activity = new
        for listener in listeners.values { listener.yield(new) }
    }

    private func addListener(_ continuation: AsyncStream<SpeechActivity>.Continuation, id: UUID) {
        listeners[id] = continuation
        continuation.yield(activity)
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }
}
