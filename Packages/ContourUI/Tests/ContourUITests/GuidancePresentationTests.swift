//
//  GuidancePresentationTests.swift
//  ContourUI — Experience / App Flow
//
//  Pins the guidance screen's rules (#151) with deterministic guidance states:
//  no camera, no simulator.
//

import ContourCore
import Foundation
import Testing
@testable import ContourUI

private let now = Date(timeIntervalSince1970: 0)

private func moving(distance: Double) -> GuidanceState {
    GuidanceState(
        timestamp: now,
        vector: GuidanceVector(direction: PanelVector(dx: 1, dy: 0), normalizedDistance: distance)
    )
}

private let allPhases: [GuidancePhase] = [
    .guiding, .searching, .findingFinger, .lostTracking, .holding, .arrived,
    .notFound, .lowConfidence, .cannotStart("The panel corners are invalid."), .stopped,
]

@Test("a finger that still has to move is guiding")
func movingFingerIsGuiding() {
    #expect(GuidancePhase(moving(distance: 0.4)) == .guiding)
}

@Test("zero distance is holding, never arrival")
func zeroDistanceIsOnlyAHold() {
    let onTarget = GuidanceState(timestamp: now, vector: .onTarget)
    #expect(GuidancePhase(onTarget) == .holding)
}

@Test("arrival appears only when the guidance system reports it")
func arrivalNeedsTheOutcome() {
    let confirmed = GuidanceState(timestamp: now, vector: .onTarget, outcome: .arrived)
    #expect(GuidancePhase(confirmed) == .arrived)
}

@Test("each outcome has its own phase")
func outcomesAreDistinct() {
    #expect(GuidancePhase(.outcome(.lostTracking, at: now)) == .lostTracking)
    #expect(GuidancePhase(.outcome(.notFound, at: now)) == .notFound)
    #expect(GuidancePhase(.outcome(.lowConfidence, at: now)) == .lowConfidence)
}

@Test("a frame with no usable guidance is searching")
func unusableFramesAreSearching() {
    #expect(GuidancePhase(GuidanceState(timestamp: now, vector: nil)) == .searching)
    #expect(GuidancePhase(moving(distance: .nan)) == .searching)
    #expect(GuidancePhase(moving(distance: -1)) == .searching)
}

@Test("a missing finger is told apart from other gaps only when the frame says so")
func missingFingerIsItsOwnPhase() {
    let gap = GuidanceState(timestamp: now, vector: nil)
    #expect(GuidancePhase(gap, fingerMissing: true) == .findingFinger)
    #expect(GuidancePhase(gap) == .searching)
    #expect(GuidancePhase(moving(distance: .nan), fingerMissing: true) == .searching)
    #expect(GuidancePhase(moving(distance: 0.4), fingerMissing: true) == .guiding)
    #expect(GuidancePhase(.outcome(.lostTracking, at: now), fingerMissing: true) == .lostTracking)
    let finger = GuidanceScreenContent(phase: .findingFinger, targetLabel: "Start")
    #expect(finger.message != GuidanceScreenContent(phase: .searching, targetLabel: "Start").message)
}

@Test("every phase has words and at least one action")
func everyPhaseHasContent() {
    for phase in allPhases {
        let content = GuidanceScreenContent(phase: phase, targetLabel: "Start")
        #expect(!content.title.isEmpty)
        #expect(!content.message.isEmpty)
        #expect(!content.actions.isEmpty)
    }
}

@Test("a running session can always be stopped, and an ended one cannot")
func stopFollowsTheSession() {
    for phase in allPhases {
        let actions = GuidanceScreenContent(phase: phase, targetLabel: "Start").actions
        #expect(actions.contains(.stop) == phase.isActive)
    }
}

@Test("every ended session offers a way forward")
func endedSessionsOfferRecovery() {
    for phase in allPhases where !phase.isActive {
        let actions = GuidanceScreenContent(phase: phase, targetLabel: "Start").actions
        #expect(actions.contains(.chooseAnother) || actions.contains(.scanAgain))
    }
}

@Test("the selected target is named, with a fallback for unlabelled buttons")
func targetIsNamed() {
    #expect(GuidanceScreenContent(phase: .guiding, targetLabel: "Start").title == "Start")
    #expect(GuidanceScreenContent(phase: .arrived, targetLabel: "Start").title == "Reached Start")
    #expect(GuidanceScreenContent(phase: .guiding, targetLabel: nil).title == "Selected button")
    #expect(GuidanceScreenContent(phase: .arrived, targetLabel: nil).message.contains("the selected button"))
}

@Test("not found and low confidence do not read the same")
func notFoundDiffersFromLowConfidence() {
    let notFound = GuidanceScreenContent(phase: .notFound, targetLabel: "Defrost")
    let unsure = GuidanceScreenContent(phase: .lowConfidence, targetLabel: "Defrost")
    #expect(notFound.title != unsure.title)
    #expect(notFound.message != unsure.message)
    #expect(notFound.actions.first == .chooseAnother)
    #expect(unsure.actions.first == .scanAgain)
}

@Test("a start failure shows its reason")
func startFailureShowsReason() {
    let content = GuidanceScreenContent(phase: .cannotStart("The panel corners are invalid."), targetLabel: "Start")
    #expect(content.message == "The panel corners are invalid.")
}

@Test("an unchanged phase is never announced again")
func repeatedPhaseIsSilent() {
    for phase in allPhases {
        #expect(GuidanceScreenContent.announcement(from: phase, to: phase, targetLabel: "Start") == nil)
    }
}

@Test("starting guidance and every ending are announced once")
func meaningfulChangesAreAnnounced() {
    #expect(GuidanceScreenContent.announcement(from: nil, to: .guiding, targetLabel: "Start") != nil)
    #expect(GuidanceScreenContent.announcement(from: .stopped, to: .guiding, targetLabel: "Start") != nil)
    for phase in allPhases where !phase.isActive {
        #expect(GuidanceScreenContent.announcement(from: .guiding, to: phase, targetLabel: "Start") != nil)
    }
    #expect(GuidanceScreenContent.announcement(from: .guiding, to: .lostTracking, targetLabel: "Start") != nil)
}

@Test("recovery from a loss is announced")
func recoveryIsAnnounced() {
    #expect(GuidanceScreenContent.announcement(from: .lostTracking, to: .guiding, targetLabel: "Start") != nil)
}

@Test("short gaps and the hold boundary stay silent")
func gapsAndHoldsAreSilent() {
    #expect(GuidanceScreenContent.announcement(from: .guiding, to: .searching, targetLabel: "Start") == nil)
    #expect(GuidanceScreenContent.announcement(from: .searching, to: .guiding, targetLabel: "Start") == nil)
    #expect(GuidanceScreenContent.announcement(from: .guiding, to: .findingFinger, targetLabel: "Start") == nil)
    #expect(GuidanceScreenContent.announcement(from: .findingFinger, to: .guiding, targetLabel: "Start") == nil)
    #expect(GuidanceScreenContent.announcement(from: .guiding, to: .holding, targetLabel: "Start") == nil)
    #expect(GuidanceScreenContent.announcement(from: .holding, to: .guiding, targetLabel: "Start") == nil)
}
