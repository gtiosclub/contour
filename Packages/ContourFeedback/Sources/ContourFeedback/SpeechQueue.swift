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

    public init(text: String, priority: SpeechPriority, expiresAfter: Duration? = nil) {
        self.text = text
        self.priority = priority
        self.expiresAfter = expiresAfter
    }
}

/// Serializes speech so utterances queue, expire, and interrupt predictably.
///
/// An `actor` because it is the one piece of state in this package that is
/// written from the camera thread and read from the speech callback.
public actor SpeechQueue {

    public init() {}

    /// Queue `utterance`, applying its priority against what is already queued.
    ///
    /// Starts speech if nothing is speaking and returns immediately. An
    /// `.interrupting` utterance clears anything pending behind the current one.
    public func enqueue(_ utterance: Utterance) async {
        fatalError("unimplemented — owned by Experience / Audio & Speech")
    }

    /// Decide what should be spoken next, given what is queued and how long each
    /// entry has been waiting.
    ///
    /// Pure and synchronous on purpose — this is the scheduling policy, and it is
    /// the part a test can pin without a synthesiser. A test asserting that an
    /// expired low-priority utterance loses to a fresh interrupting one is worth
    /// writing before any AVSpeechSynthesizer code exists.
    ///
    /// - Parameters:
    ///   - queued: everything waiting, oldest first, each with how long it has
    ///     been waiting.
    ///   - isSpeaking: whether something is being spoken right now.
    /// - Returns: the utterance to speak next, or `nil` to stay silent.
    public nonisolated func next(
        from queued: [(utterance: Utterance, waiting: Duration)],
        isSpeaking: Bool
    ) -> Utterance? {
        fatalError("unimplemented — owned by Experience / Audio & Speech")
    }

    /// Stop speaking and drop everything queued. Must be safe to call when idle.
    ///
    /// Called when a guidance session ends. Speech outliving its session is the
    /// bug that makes the app feel haunted.
    public func stop() async {
        fatalError("unimplemented — owned by Experience / Audio & Speech")
    }
}
