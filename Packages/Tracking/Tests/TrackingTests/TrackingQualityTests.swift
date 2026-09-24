//
//  TrackingQualityTests.swift
//  Tracking — Tracking / Tracking Assessment
//

import ContourCore
import Foundation
import Testing
@testable import Tracking

private let t0 = Date(timeIntervalSince1970: 1_767_225_600)

/// A centred panel, optionally shifted right by `dx` image widths.
private func quad(shiftedBy dx: Double = 0) -> PanelQuad {
    PanelQuad(topLeft: ImagePoint(x: 0.2 + dx, y: 0.2),
              topRight: ImagePoint(x: 0.8 + dx, y: 0.2),
              bottomRight: ImagePoint(x: 0.8 + dx, y: 0.8),
              bottomLeft: ImagePoint(x: 0.2 + dx, y: 0.8))
}

/// Everything working.
private func healthy(at offset: TimeInterval = 0, shiftedBy dx: Double = 0) -> TrackingObservation {
    TrackingObservation(timestamp: t0.addingTimeInterval(offset), fingertipConfidence: 0.9,
                        panelQuad: quad(shiftedBy: dx), panelConfidence: 0.9)
}

private let evaluator = TrackingQualityEvaluator()

@Test("a confident panel and fingertip are good")
func healthyIsGood() {
    let assessment = evaluator.assess(healthy())
    #expect(assessment.quality == .good)
    #expect(assessment.reason == .tracking)
    #expect(assessment.timestamp == t0)
}

@Test("a missing panel is lost")
func missingPanelIsLost() {
    var observation = healthy()
    observation.panelQuad = nil
    #expect(evaluator.assess(observation).reason == .panelNotLocated)
    #expect(evaluator.assess(observation).quality == .lost)
}

@Test("a removed hand degrades, it doesn't lose the panel")
func missingFingertipIsDegraded() {
    var observation = healthy()
    observation.fingertipConfidence = nil
    let assessment = evaluator.assess(observation)
    #expect(assessment.quality == .degraded)
    #expect(assessment.reason == .noFingertip)
}

@Test("panel confidence: at the floor is lost, mid-band is degraded")
func panelConfidenceBands() {
    var observation = healthy()
    observation.panelConfidence = 0.2
    #expect(evaluator.assess(observation).quality == .lost)
    observation.panelConfidence = 0.45
    #expect(evaluator.assess(observation).quality == .degraded)
    #expect(evaluator.assess(observation).reason == .panelConfidenceLow)
}

@Test("a low-confidence fingertip is degraded")
func lowFingertipIsDegraded() {
    var observation = healthy()
    observation.fingertipConfidence = 0.3
    #expect(evaluator.assess(observation).reason == .fingertipConfidenceLow)
}

@Test("stale data degrades, then goes lost")
func staleness() {
    #expect(evaluator.assess(healthy(), asOf: t0.addingTimeInterval(0.02)).quality == .good)
    #expect(evaluator.assess(healthy(), asOf: t0.addingTimeInterval(0.2)).quality == .degraded)
    let old = evaluator.assess(healthy(), asOf: t0.addingTimeInterval(0.75))
    #expect(old.quality == .lost)
    #expect(old.reason == .stale)
}

@Test("a panel that jumps half the frame in one frame time is lost")
func implausibleJumpIsLost() {
    // ~15 image widths per second.
    let assessment = evaluator.assess(healthy(at: 0.033, shiftedBy: 0.5), previous: healthy())
    #expect(assessment.quality == .lost)
    #expect(assessment.reason == .panelJumped)
}

@Test("ordinary hand-held drift stays good")
func plausibleDriftIsGood() {
    #expect(evaluator.assess(healthy(at: 0.033, shiftedBy: 0.02), previous: healthy()).quality == .good)
}

@Test("a duplicate timestamp isn't infinite speed, and the first frame has nothing to compare")
func jumpCheckNeedsTwoFrames() {
    #expect(evaluator.assess(healthy(shiftedBy: 0.5), previous: healthy()).quality == .good)
    #expect(evaluator.assess(healthy(shiftedBy: 0.5), previous: nil).quality == .good)
}

@Test("motion is per corner, so a fold-over is caught")
func foldOverIsCaught() {
    let start = quad()
    let folded = PanelQuad(topLeft: start.topRight, topRight: start.topLeft,
                           bottomRight: start.bottomLeft, bottomLeft: start.bottomRight)
    #expect(TrackingQualityEvaluator.cornerShift(start, folded) > 0.5)
}

@Test("thresholds are configurable")
func thresholdsAreConfigurable() {
    var observation = healthy()
    observation.fingertipConfidence = 0.3
    var lenient = TrackingQualityThresholds()
    lenient.fingertipGood = 0.1
    #expect(TrackingQualityEvaluator(thresholds: lenient).assess(observation).quality == .good)

    // What the fingertip-only debug screen does.
    var noPanel = TrackingQualityThresholds()
    noPanel.panelRequired = false
    let fingerOnly = TrackingObservation(timestamp: t0, fingertipConfidence: 0.9)
    #expect(TrackingQualityEvaluator(thresholds: noPanel).assess(fingerOnly).quality == .good)
}

@Test("good → degraded → lost → good replays as scripted")
func scriptedSequence() {
    var degraded = healthy(at: 0.033)
    degraded.fingertipConfidence = 0.2
    var lost = healthy(at: 0.066)
    lost.panelQuad = nil

    var previous: TrackingObservation?
    var results: [TrackingAssessment] = []
    for observation in [healthy(at: 0), degraded, lost, healthy(at: 0.099)] {
        results.append(evaluator.assess(observation, previous: previous, asOf: observation.timestamp))
        previous = observation
    }

    #expect(results.map(\.quality) == [.good, .degraded, .lost, .good])
    #expect(results.map(\.reason) == [.tracking, .fingertipConfidenceLow, .panelNotLocated, .tracking])
}

@Test("every cause of loss reports lost, never tracking")
func lostIsNeverUsable() {
    var noPanel = healthy()
    noPanel.panelQuad = nil
    var noConfidence = healthy()
    noConfidence.panelConfidence = 0.05

    for observation in [noPanel, noConfidence] {
        let assessment = evaluator.assess(observation)
        #expect(assessment.quality == .lost, "\(assessment.summary)")
        #expect(assessment.reason != .tracking)
    }
    #expect(evaluator.assess(healthy(at: 0.033, shiftedBy: 0.9), previous: healthy()).quality == .lost)
    #expect(evaluator.assess(healthy(), asOf: t0.addingTimeInterval(1)).quality == .lost)
}

@Test("reasons are displayable")
func reasonsAreDisplayable() {
    #expect(TrackingQualityReason.allCases.allSatisfy { !$0.message.isEmpty })
    let assessment = TrackingAssessment(timestamp: t0, quality: .degraded, reason: .stale)
    #expect(assessment.summary == "Degraded — Observation is stale")
}