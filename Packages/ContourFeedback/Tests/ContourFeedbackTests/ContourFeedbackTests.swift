//
//  ContourFeedbackTests.swift
//  ContourFeedback — Team 3
//
//  One structural test so CI is green on day one. Team 3: delete this and write
//  real tests. Feedback is unusually testable for a sensory feature — assert on
//  the pattern you would hand to Core Haptics, not on what it feels like.
//

import ContourCore
import Testing
@testable import ContourFeedback

@Test("LiveFeedbackEngine still satisfies the ContourCore contract")
func conformsToContract() {
    let subject: any FeedbackEngine = LiveFeedbackEngine()
    #expect(subject is LiveFeedbackEngine)
}
