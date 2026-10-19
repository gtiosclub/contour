//
//  HybridAlignmentTests.swift
//  Tracking — Tracking / Geometry and fusion
//
//  A synthetic panel 50 cm in front of a synthetic camera. The "visual tracker"
//  here is task 1's projection of the true corners, so these tests exercise the
//  calibration decisions rather than any detector.
//

import ContourCore
import Foundation
import Testing
import simd
@testable import Tracking

// MARK: - The scene

private let sensor = SIMD2<Float>(1920, 1440)
private let focal: Float = 1500
private let session = UUID()
private let start = Date(timeIntervalSince1970: 1_767_225_600)

/// A 20 × 15 cm panel, flat on, half a metre away.
///
/// Camera +x is portrait-down and +y is portrait-right, so the world corner
/// that shows up top-left in the image is the one at (-x, -y).
private let truePanel = WorldPanelCorners(
    topLeft: SIMD3(-0.075, -0.1, -0.5),
    topRight: SIMD3(-0.075, 0.1, -0.5),
    bottomRight: SIMD3(0.075, 0.1, -0.5),
    bottomLeft: SIMD3(0.075, -0.1, -0.5)
)

/// A plane facing the camera, `distance` metres away. Local y is its normal.
private func surface(at distance: Float, extent: SIMD2<Float> = SIMD2(0.6, 0.6)) -> WorldPlane {
    WorldPlane(
        transform: simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, -1, 0, 0),
            SIMD4(0, 0, -distance, 1)
        ),
        extent: extent
    )
}

private func camera(
    at translation: SIMD3<Float>,
    turnedBy radians: Float = 0,
    planes: [WorldPlane],
    normalTracking: Bool = true
) -> WorldCameraSnapshot {
    var transform = radians == 0
        ? matrix_identity_float4x4
        : simd_float4x4(simd_quatf(angle: radians, axis: SIMD3(0, 1, 0)))
    transform.columns.3 = SIMD4(translation, 1)
    return WorldCameraSnapshot(
        sessionID: session,
        cameraToWorld: transform,
        intrinsics: simd_float3x3(SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(960, 720, 1)),
        imageSize: sensor,
        normalTracking: normalTracking,
        planes: planes
    )
}

/// What a working visual tracker would report from this camera: the true panel,
/// projected. Confidence is high unless a test wants a weak view.
private func seen(from snapshot: WorldCameraSnapshot, at offset: TimeInterval,
                  confidence: Double = 0.9) throws -> PanelObservation {
    let quad = try PanelWorldGeometry(snapshot: snapshot).quad(for: truePanel)
    return .tracked(quad, confidence: confidence, at: start.addingTimeInterval(offset))
}

/// Walk the camera and feed every view through the policy.
@discardableResult
private func walk(
    _ alignment: inout HybridAlignment,
    steps: Int,
    step: SIMD3<Float>,
    interval: TimeInterval = 0.15,
    planes: [WorldPlane],
    turnPerStep: Float = 0
) throws -> [PanelObservation] {
    var results: [PanelObservation] = []
    for i in 0..<steps {
        let snapshot = camera(at: step * Float(i), turnedBy: turnPerStep * Float(i), planes: planes)
        let observation = try seen(from: snapshot, at: Double(i) * interval)
        results.append(alignment.update(visual: observation, world: snapshot))
    }
    return results
}

/// 1 cm sideways per view: 10 views cover 9 cm in 1.35 s, which clears the
/// eight-view, one-second and 6 cm readiness gates.
private let sideways = SIMD3<Float>(0, 0.01, 0)

// MARK: - Successful calibration

@Test("sideways movement across a real panel plane calibrates")
func sidewaysCalibrates() throws {
    var alignment = HybridAlignment()

    let results = try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.5)])

    #expect(alignment.isCalibrated)
    #expect(alignment.model != nil)
    #expect(alignment.model?.acceptedViews ?? 0 >= 8)
    #expect(alignment.model?.sessionID == session)
    // Distance to the top-left corner, which is what plane selection ranks on:
    // √(0.075² + 0.1² + 0.5²) = 0.5154, not the 0.5 m to the panel's centre.
    #expect(abs((alignment.model?.firstDistance ?? 0) - 0.5154) < 0.001)
    #expect(results.last?.hybridDiagnostics?.calibrationReady == true)
}

@Test("the approved corners are the panel's, not the plane's centre")
func approvedCornersMatchTheTruePanel() throws {
    var alignment = HybridAlignment()

    try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.5)])
    let corners = try #require(alignment.model?.corners)

    for (approved, truth) in zip(corners.all, truePanel.all) {
        #expect(simd_distance(approved, truth) < 1e-6)
    }
}

@Test("while calibrating, the caller keeps getting its own 2D alignment back")
func visualOutputIsPassedThroughWhileCalibrating() throws {
    var alignment = HybridAlignment()

    for i in 0..<10 {
        let snapshot = camera(at: sideways * Float(i), planes: [surface(at: 0.5)])
        let observation = try seen(from: snapshot, at: Double(i) * 0.15)
        let wasCalibrated = alignment.isCalibrated
        let out = alignment.update(visual: observation, world: snapshot)

        guard !wasCalibrated else { break }  // fusion takes over from here
        #expect(out.quad == observation.quad)
        #expect(out.hybridDiagnostics?.source == .visual, "calibration fuses nothing")
    }
}

// MARK: - Wrong depth

@Test("a background surface is rejected once the phone moves")
func backgroundPlaneIsRejected() throws {
    var alignment = HybridAlignment()
    // A shelf 15 cm behind the panel. It explains the first view perfectly, and
    // at a 2 cm baseline it still agrees in 2D to ~0.007 — inside the 0.025
    // corner tolerance. Only triangulation catches it.
    let results = try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.65)])

    #expect(!alignment.isCalibrated)
    #expect(alignment.model == nil)
    #expect(results.contains { $0.hybridDiagnostics?.resetCount ?? 0 > 0 }, "the candidate was discarded")
    #expect(results.contains { $0.hybridDiagnostics?.lastResetReason?.contains("depth") == true })
}

@Test("a far wall never calibrates either")
func farWallNeverCalibrates() throws {
    var alignment = HybridAlignment()

    try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.8)])

    #expect(!alignment.isCalibrated)
}

@Test("the real plane is preferred when both are offered")
func nearestValidPlaneWins() throws {
    var alignment = HybridAlignment()

    try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.8), surface(at: 0.5)])

    #expect(alignment.isCalibrated, "nearest-by-first-corner picks the panel's own surface")
}

// MARK: - Motion that proves nothing

@Test("moving straight at the panel never establishes depth")
func forwardOnlyMotionIsInsufficient() throws {
    var alignment = HybridAlignment()

    // 9 cm of travel in 1.35 s over ten accepted views: every gate except depth
    // is satisfied, and it still must not calibrate.
    let results = try walk(&alignment, steps: 10, step: SIMD3(0, 0, -0.01), planes: [surface(at: 0.5)])

    #expect(!alignment.isCalibrated)
    #expect(results.last?.hybridDiagnostics?.calibrationFrames ?? 0 >= 8, "views were accepted")
    #expect(results.last?.hybridDiagnostics?.mode == .calibrating, "still asking, not refusing")
}

@Test("turning on the spot never establishes depth")
func rotationOnlyIsInsufficient() throws {
    var alignment = HybridAlignment()

    try walk(&alignment, steps: 10, step: .zero, planes: [surface(at: 0.5)], turnPerStep: 0.01)

    #expect(!alignment.isCalibrated, "no parallax from a camera that hasn't moved")
}

@Test("a few millimetres of movement is not a second viewpoint")
func insufficientMovementIsNotReady() throws {
    var alignment = HybridAlignment()

    // 0.5 mm per view: 4.5 mm in total, nowhere near the 6 cm baseline gate.
    let results = try walk(&alignment, steps: 10, step: SIMD3(0, 0.0005, 0), planes: [surface(at: 0.5)])

    #expect(!alignment.isCalibrated)
    #expect(results.last?.hybridDiagnostics?.baselineCentimeters ?? 99 < 1)
}

// MARK: - Progress is kept

@Test("a frame of unreliable world tracking holds progress instead of resetting")
func unreliableWorldHoldsProgress() throws {
    var alignment = HybridAlignment()
    try walk(&alignment, steps: 5, step: sideways, planes: [surface(at: 0.5)])

    let interrupted = camera(at: sideways * 5, planes: [surface(at: 0.5)], normalTracking: false)
    let held = alignment.update(visual: try seen(from: interrupted, at: 0.75), world: interrupted)

    #expect(held.hybridDiagnostics?.calibrationFrames ?? 0 >= 2, "views kept")
    #expect(!alignment.didReset)

    // And the run can still finish.
    for i in 6..<12 {
        let snapshot = camera(at: sideways * Float(i), planes: [surface(at: 0.5)])
        _ = alignment.update(visual: try seen(from: snapshot, at: Double(i) * 0.15), world: snapshot)
    }
    #expect(alignment.isCalibrated)
}

@Test("losing the panel for a frame holds progress too")
func visualLossHoldsProgress() throws {
    var alignment = HybridAlignment()
    try walk(&alignment, steps: 5, step: sideways, planes: [surface(at: 0.5)])

    let snapshot = camera(at: sideways * 5, planes: [surface(at: 0.5)])
    let lost = alignment.update(
        visual: .lost(.notFound, at: start.addingTimeInterval(0.75)), world: snapshot)

    #expect(lost.quad == nil, "a lost frame stays lost")
    #expect(lost.hybridDiagnostics?.calibrationFrames ?? 0 >= 2)
    #expect(!alignment.didReset)
}

// MARK: - Starting conditions and invalidation

@Test("a weak visual view is not a starting point")
func weakViewDoesNotStartCalibration() throws {
    var alignment = HybridAlignment()
    let snapshot = camera(at: .zero, planes: [surface(at: 0.5)])

    let result = alignment.update(
        visual: try seen(from: snapshot, at: 0, confidence: 0.4), world: snapshot)

    #expect(result.hybridDiagnostics?.calibrationFrames == 0)
    #expect(!alignment.acceptedCalibrationView)
}

@Test("with no plane offered there is nothing to calibrate against")
func noPlaneMeansNoCandidate() throws {
    var alignment = HybridAlignment()
    let snapshot = camera(at: .zero, planes: [])

    let result = alignment.update(visual: try seen(from: snapshot, at: 0), world: snapshot)

    #expect(result.hybridDiagnostics?.mode == .visual)
    #expect(!alignment.isCalibrated)
}

@Test("a missing world snapshot falls back to 2D and clears world calibration")
func missingWorldClearsCalibration() throws {
    var alignment = HybridAlignment()
    try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.5)])
    #expect(alignment.isCalibrated)

    let snapshot = camera(at: sideways * 10, planes: [surface(at: 0.5)])
    let result = alignment.update(visual: try seen(from: snapshot, at: 1.5), world: nil)

    #expect(!alignment.isCalibrated)
    #expect(alignment.model == nil)
    #expect(alignment.didReset)
    #expect(result.hybridDiagnostics?.mode == .visual)
    #expect(result.quad != nil, "2D output continues")
}

@Test("a replaced world session invalidates the stored corners")
func newSessionInvalidates() throws {
    var alignment = HybridAlignment()
    try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.5)])

    let replaced = WorldCameraSnapshot(
        sessionID: UUID(),
        cameraToWorld: matrix_identity_float4x4,
        intrinsics: simd_float3x3(SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(960, 720, 1)),
        imageSize: sensor,
        normalTracking: true,
        planes: [surface(at: 0.5)]
    )
    let result = alignment.update(visual: try seen(from: replaced, at: 1.5), world: replaced)

    #expect(!alignment.isCalibrated)
    #expect(alignment.didReset)
    #expect(result.quad != nil)
}

// MARK: - Events

@Test("accepted-view and reset flags describe only the latest update")
func eventFlagsAreNotSticky() throws {
    var alignment = HybridAlignment()
    let first = camera(at: .zero, planes: [surface(at: 0.5)])

    _ = alignment.update(visual: try seen(from: first, at: 0), world: first)
    #expect(alignment.acceptedCalibrationView, "the opening view is accepted")

    // Same place, 30 ms later: not a new viewpoint.
    let crowded = camera(at: .zero, planes: [surface(at: 0.5)])
    _ = alignment.update(visual: try seen(from: crowded, at: 0.03), world: crowded)
    #expect(!alignment.acceptedCalibrationView)
    #expect(!alignment.didReset)

    // A proper second viewpoint is accepted again.
    let moved = camera(at: sideways, planes: [surface(at: 0.5)])
    _ = alignment.update(visual: try seen(from: moved, at: 0.2), world: moved)
    #expect(alignment.acceptedCalibrationView)
}

@Test("calibration does not ask for feature restoration — that is task 3")
func featureRestoreStaysQuiet() throws {
    var alignment = HybridAlignment()

    let results = try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.5)])

    #expect(!alignment.needsFeatureRestore)
    #expect(results.allSatisfy { $0.hybridDiagnostics?.repositionReason == nil })
}

// MARK: - Thresholds

@Test("readiness gates are configurable")
func calibrationThresholdsAreConfigurable() throws {
    var strict = HybridAlignment.Thresholds()
    strict.readyBaseline = 0.5
    var alignment = HybridAlignment(thresholds: strict)

    try walk(&alignment, steps: 10, step: sideways, planes: [surface(at: 0.5)])

    #expect(!alignment.isCalibrated, "9 cm of movement no longer clears a 50 cm gate")
}

@Test("it satisfies the shared policy contract")
func conformsToPanelAlignmentPolicy() {
    var policy: any PanelAlignmentPolicy = HybridAlignment()
    #expect(!policy.isCalibrated)
    #expect(policy.update(visual: .lost(.notStarted, at: start), world: nil).quad == nil)
}
