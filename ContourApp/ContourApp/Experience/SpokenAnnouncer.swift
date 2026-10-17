//
//  SpokenAnnouncer.swift
//  ContourApp — Experience / Accessibility & Launch
//
//  Where the flow's words go. With VoiceOver running they are VoiceOver
//  announcements, so they share its voice, rate and queue; without it (a
//  low-vision user who doesn't use VoiceOver) they are spoken through
//  ContourFeedback's SpeechQueue. Wiring only — the words are ContourUI's.
//

import ContourFeedback
import SwiftUI
import UIKit

final class SpokenAnnouncer {

    private let speech = SpeechQueue()

    /// Says `text`.
    ///
    /// - Parameter interrupt: `true` for a stage change, which replaces
    ///   whatever is being said; `false` for a follow-up (an error, what was
    ///   heard), which waits its turn.
    func say(_ text: String, interrupt: Bool) async {
        if UIAccessibility.isVoiceOverRunning {
            var message = AttributedString(text)
            message.accessibilitySpeechAnnouncementPriority = interrupt ? .high : .low
            AccessibilityNotification.Announcement(message).post()
        } else {
            await speech.enqueue(Utterance(text: text, priority: interrupt ? .interrupting : .normal,
                                           expiresAfter: .seconds(10)))
        }
    }
}
