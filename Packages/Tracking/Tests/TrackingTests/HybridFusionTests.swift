//
//  HybridFusionTests.swift
//  Tracking — Tracking / Geometry and fusion
//
//  What happens after calibration: correction, prediction, conflict, recovery.
//  Every case checks geometry, source and events together — a message string
//  saying "predicting" proves nothing on its own.
//

import ContourCore
import Foundation
import Testing
import simd
@testable import Tracking

// MARK: - Correction

@Test("an agreeing visual match corrects the model and reports a fused source")
func agreeingMatchFuses() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    let result = try driver.step()

    #expect(result.hybridDiagnostics?.source == .fused)
    #expect(result.hybridDiagnostics?.mode == .corrected)
    #expect(result.quad != nil)
    #expect(result.hybridDiagnostics?.visualVerificationAge ?? 99 < 0.001, "just verified")
    #expect(driver.alignment.isCalibrated)
}

@Test("corrections move the stored corners gently, not all at once")
func correctionsAreSmoothed() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    let before = try #require(driver.alignment.model?.corners)

    // A match 1 cm off: inside the 0.04 agreement tolerance, so it corrects.
    try driver.stepDisplaced(by: 0.01)
    let after = try #require(driver.alignment.model?.corners)

    let moved = simd_distance(before.topLeft, after.topLeft)
    #expect(moved > 0, "it did correct")
    #expect(moved < 0.004, "but kept 80% of the stored corners")
}

@Test("a weak visual match corrects nothing")
func weakMatchDoesNotCorrect() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    let before = try #require(driver.alignment.model?.corners)

    let result = try driver.step(confidence: 0.4)

    #expect(driver.alignment.model?.corners.topLeft == before.topLeft)
    #expect(result.hybridDiagnostics?.source == .world, "predicted, not fused")
}

// MARK: - Prediction

@Test("when the panel disappears the model is projected from the current pose")
func visualLossPredicts() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    let lastSeen = try #require(try driver.step().quad)

    let predicted = try driver.stepLost()

    let quad = try #require(predicted.quad)
    #expect(predicted.hybridDiagnostics?.source == .world)
    #expect(predicted.hybridDiagnostics?.mode == .predicted)
    #expect(predicted.confidence == 0.55, "world-only confidence")
    #expect(quad.topLeft != lastSeen.topLeft,
            "a newly calculated position, not the last screen coordinates")
}

@Test("prediction does not expire just because the last sighting is old")
func predictionSurvivesAnOldVerification() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    var last: PanelObservation?
    for _ in 0..<20 { last = try driver.stepLost(by: .zero) }  // 3 s without a sighting

    #expect(last?.hybridDiagnostics?.source == .world)
    #expect(last?.quad != nil)
    #expect(last?.hybridDiagnostics?.visualVerificationAge ?? 0 > 2.5, "and says how stale it is")
}

@Test("a panel that cannot be projected is reported lost, never as old corners")
func unprojectablePanelIsLost() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    // Walk far enough sideways that the panel leaves the frame entirely.
    var last: PanelObservation?
    for _ in 0..<40 { last = try driver.stepLost(by: SIMD3(0, 0.05, 0)) }

    #expect(last?.quad == nil)
    #expect(last?.hybridDiagnostics?.source == .unavailable)
}

// MARK: - Conflict

@Test("a displaced match is ignored during the grace period")
func briefConflictKeepsPredicting() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    let before = try #require(driver.alignment.model?.corners)

    let result = try driver.stepDisplaced()

    #expect(result.hybridDiagnostics?.source == .world, "the prediction is kept")
    #expect(result.hybridDiagnostics?.repositionReason == .weakAlignment)
    #expect(driver.alignment.model?.corners.topLeft == before.topLeft, "geometry untouched")
    #expect(!driver.alignment.didReset)
}

@Test("a conflicting match does not refresh the verification time")
func conflictDoesNotCountAsVerification() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    try driver.step()

    try driver.stepLost(by: .zero)
    let conflicted = try driver.stepDisplaced(offset: .zero)

    #expect(conflicted.hybridDiagnostics?.visualVerificationAge ?? 0 >= 0.3,
            "age keeps running through the disagreement")
}

@Test("a saturated frame marks the disagreement as suspected glare")
func glareIsReportedAsAHeuristic() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    let result = try driver.stepDisplaced(saturated: 0.3)

    #expect(result.hybridDiagnostics?.repositionReason == .suspectedGlare)
    #expect(result.hybridDiagnostics?.source == .world, "a hunch about glare changes no geometry")
}

@Test("sustained disagreement resets the model and returns to 2D")
func sustainedConflictResets() throws {
    // 0.25 s apart, so three conflicts clearly span the 0.4 s the reset rule
    // asks for — 0.2 s would land exactly on it, where accumulated timestamps
    // come out a hair short.
    var driver = HybridDriver(interval: 0.25)
    try driver.calibrate()

    var results: [PanelObservation] = []
    for _ in 0..<3 { results.append(try driver.stepDisplaced(offset: .zero)) }

    #expect(!driver.alignment.isCalibrated)
    #expect(driver.alignment.model == nil)
    #expect(results.last?.hybridDiagnostics?.mode == .visual, "visual-led again")
    #expect(results.last?.hybridDiagnostics?.lastResetReason?.contains("disagree") == true)
    #expect(results.contains { $0.hybridDiagnostics?.resetCount ?? 0 > 0 })
}

@Test("grace expires even when the conflicting matches stop arriving")
func graceExpiresWithoutFurtherMatches() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    try driver.stepDisplaced(offset: .zero)           // one conflict, then silence
    var last: PanelObservation?
    for _ in 0..<4 { last = try driver.stepLost(by: .zero) }  // 0.6 s later

    #expect(last?.hybridDiagnostics?.source == .unavailable, "prediction paused")
    #expect(last?.quad == nil)
    #expect(driver.alignment.isCalibrated, "not enough evidence to reset, though")
    #expect(driver.alignment.model != nil)
}

@Test("agreement clears the conflict run")
func agreementClearsConflict() throws {
    var driver = HybridDriver(interval: 0.2)
    try driver.calibrate()

    try driver.stepDisplaced(offset: .zero)
    try driver.stepDisplaced(offset: .zero)
    let recovered = try driver.step(by: .zero)        // an agreeing match
    #expect(recovered.hybridDiagnostics?.source == .fused)

    // Two fresh conflicts are not three: the run started over.
    try driver.stepDisplaced(offset: .zero)
    let second = try driver.stepDisplaced(offset: .zero)

    #expect(driver.alignment.isCalibrated)
    #expect(second.hybridDiagnostics?.mode != .visual)
}

// MARK: - World interruption

@Test("unreliable world tracking pauses prediction immediately but keeps calibration")
func unreliableWorldPausesPrediction() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    let interrupted = try driver.step(normalTracking: false)

    #expect(interrupted.hybridDiagnostics?.mode == .reacquiring)
    #expect(interrupted.hybridDiagnostics?.source != .world, "nothing is predicted while AR is unreliable")
    #expect(driver.alignment.isCalibrated, "calibration is retained through a passing limitation")
}

@Test("prediction resumes only after an agreeing visual match")
func predictionWaitsForReverification() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    try driver.step(normalTracking: false)

    // World tracking is fine again, but nothing has verified the model yet.
    let stillPaused = try driver.stepLost()
    #expect(stillPaused.hybridDiagnostics?.source == .unavailable)
    #expect(stillPaused.quad == nil)

    // An agreeing match re-verifies it...
    let verified = try driver.step()
    #expect(verified.hybridDiagnostics?.source == .fused)

    // ...and prediction is available again.
    let predicted = try driver.stepLost()
    #expect(predicted.hybridDiagnostics?.source == .world)
    #expect(predicted.quad != nil)
}

@Test("2D output continues while prediction is paused")
func pausedPredictionStillPassesVisualThrough() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    try driver.step(normalTracking: false)

    let weakButPresent = try driver.step(confidence: 0.4, normalTracking: false)

    #expect(weakButPresent.quad != nil, "the caller's own 2D alignment is still useful")
    #expect(weakButPresent.hybridDiagnostics?.source == .visual)
}

// MARK: - Recovery events

@Test("a dry spell asks for the original features back, once")
func featureRestoreIsRequestedOnce() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    var requests = 0
    for _ in 0..<8 {
        try driver.stepLost(by: .zero)
        if driver.alignment.needsFeatureRestore { requests += 1 }
    }

    #expect(requests == 1, "an event, not a condition")

    // A correction clears it, so the next dry spell can ask again.
    try driver.step(by: .zero)
    #expect(!driver.alignment.needsFeatureRestore)
    var asked = false
    for _ in 0..<6 {
        try driver.stepLost(by: .zero)
        asked = asked || driver.alignment.needsFeatureRestore
    }
    #expect(asked)
}

@Test("the policy never calls a feature tracker to do it")
func restorationIsOnlyARequest() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    // Nothing to assert about OpenCV because nothing can reach it: the policy
    // holds no tracker. This pins the flag as the whole mechanism.
    var asked = false
    for _ in 0..<8 {
        try driver.stepLost(by: .zero)
        asked = asked || driver.alignment.needsFeatureRestore
    }
    #expect(asked)
    #expect(driver.alignment.model != nil, "and asking changes no geometry")
}

// MARK: - Invalidation

@Test("an absent world snapshot drops to 2D and clears the world model")
func absentSnapshotClearsTheModel() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    let result = try driver.stepWithoutWorld()

    #expect(!driver.alignment.isCalibrated)
    #expect(driver.alignment.model == nil)
    #expect(driver.alignment.didReset)
    #expect(result.quad != nil)
    #expect(result.hybridDiagnostics?.source == .visual)
}

@Test("a replaced world session invalidates the model mid-prediction")
func replacedSessionInvalidatesTheModel() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    let replaced = HybridScene.camera(
        at: driver.position, planes: driver.planes, session: UUID())
    let result = driver.alignment.update(
        visual: try HybridScene.seen(from: replaced, at: driver.elapsed + 0.15), world: replaced)

    #expect(!driver.alignment.isCalibrated)
    #expect(driver.alignment.didReset)
    #expect(result.hybridDiagnostics?.source == .visual)
}

@Test("a replaced panel reference invalidates the model on request")
func replacedReferenceInvalidatesTheModel() throws {
    var driver = HybridDriver()
    try driver.calibrate()

    driver.alignment.invalidate()

    #expect(!driver.alignment.isCalibrated)
    #expect(driver.alignment.model == nil)
    #expect(driver.alignment.didReset, "the coordinator sees the reset as an event")

    // The next frame is ordinary visual-led calibration again.
    let result = try driver.step()
    #expect(result.hybridDiagnostics?.source == .visual)
    #expect(result.quad != nil)
}

@Test("after a reset it calibrates again from scratch")
func resetReturnsToCalibration() throws {
    var driver = HybridDriver()
    try driver.calibrate()
    try driver.stepWithoutWorld()
    #expect(!driver.alignment.isCalibrated)

    try driver.calibrate(step: -HybridScene.sideways)

    #expect(driver.alignment.isCalibrated, "visual-led calibration picks it up again")
}

// MARK: - Thresholds

@Test("the agreement tolerance is configurable")
func fusionThresholdsAreConfigurable() throws {
    var loose = HybridAlignment.Thresholds()
    loose.correctedCornerError = 0.2
    loose.correctedRMS = 0.2
    var driver = HybridDriver(alignment: HybridAlignment(thresholds: loose))
    try driver.calibrate()

    // The same 0.06 displacement that conflicts by default now corrects.
    let result = try driver.stepDisplaced(offset: .zero)

    #expect(result.hybridDiagnostics?.source == .fused)
}
