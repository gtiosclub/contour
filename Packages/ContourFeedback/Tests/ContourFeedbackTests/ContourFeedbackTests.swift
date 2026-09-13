//
//  ContourFeedbackTests.swift
//  ContourFeedback — Team 3
//
//  Structural tests so CI is green on day one.
//
//  Team 3: feedback is more testable than it sounds. Assert on the PATTERN you
//  would hand to Core Haptics — event times, intensities, sharpness — not on
//  what it feels like. Two tests worth writing first:
//
//    1. distance 0.8 and distance 0.2 produce measurably different patterns
//    2. .notFound and .lowConfidence produce different haptic signatures
//
//  Both are writable before you have a single line of Core Haptics code.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

@Test("LiveFeedbackEngine still satisfies the ContourCore contract")
func conformsToContract() {
    let subject: any FeedbackEngine = LiveFeedbackEngine()
    #expect(subject is LiveFeedbackEngine)
}

@Test("the feedback channels are constructible")
func channelsExist() {
    _ = ProximityHaptics()
    _ = DirectionalAudio()
    _ = OutcomeAnnouncer()
}

@Test("there are exactly four outcomes to design for")
func fourOutcomes() {
    #expect(OutcomeSignal.allCases.count == 4)
}

@Test("the Week 2 bake-off has candidates and has not been decided yet")
func bakeOffPending() {
    #expect(GuidanceModelKind.allCases.count >= 2, "a bake-off needs candidates")
    #expect(
        ChosenGuidanceModel.kind == nil,
        "set this at the end of Week 2 and record why in the PR"
    )
}

@Test("+dy is down: a target below the finger points downward")
func axisConventionHolds() {
    let finger = PanelPoint(x: 0.5, y: 0.2)
    let target = PanelPoint(x: 0.5, y: 0.8)

    #expect(finger.vector(to: target).dy > 0, "target below the finger means +dy")
}
