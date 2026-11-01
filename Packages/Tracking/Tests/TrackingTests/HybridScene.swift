//
//  HybridScene.swift
//  Tracking — Tracking / Geometry and fusion
//
//  The synthetic scene the calibration and fusion tests share: one panel, one
//  camera, no ARSession and no detector. The "visual tracker" is task 1's
//  projection of the true corners, so the tests exercise decisions, not Vision.
//

import ContourCore
import Foundation
import simd
@testable import Tracking

enum HybridScene {
    static let sensor = SIMD2<Float>(1920, 1440)
    static let focal: Float = 1500
    static let session = UUID()
    static let start = Date(timeIntervalSince1970: 1_767_225_600)

    /// A 20 × 15 cm panel, flat on, half a metre away.
    ///
    /// Camera +x is portrait-down and +y is portrait-right, so the corner that
    /// shows up top-left in the image is the one at (-x, -y).
    static let truePanel = WorldPanelCorners(
        topLeft: SIMD3(-0.075, -0.1, -0.5),
        topRight: SIMD3(-0.075, 0.1, -0.5),
        bottomRight: SIMD3(0.075, 0.1, -0.5),
        bottomLeft: SIMD3(0.075, -0.1, -0.5)
    )

    /// 1 cm of sideways travel: ten views cover 9 cm in 1.35 s, which clears the
    /// eight-view, one-second and 6 cm readiness gates.
    static let sideways = SIMD3<Float>(0, 0.01, 0)

    /// A plane facing the camera, `distance` metres away. Local y is its normal.
    static func surface(at distance: Float, extent: SIMD2<Float> = SIMD2(0.6, 0.6)) -> WorldPlane {
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

    static func camera(
        at translation: SIMD3<Float>,
        turnedBy radians: Float = 0,
        planes: [WorldPlane],
        normalTracking: Bool = true,
        session: UUID = HybridScene.session
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

    /// What a working visual tracker would report from this camera.
    static func seen(
        from snapshot: WorldCameraSnapshot, at offset: TimeInterval, confidence: Double = 0.9
    ) throws -> PanelObservation {
        let quad = try PanelWorldGeometry(snapshot: snapshot).quad(for: truePanel)
        return .tracked(quad, confidence: confidence, at: start.addingTimeInterval(offset))
    }

    /// Feature evidence carrying nothing but a saturated fraction, for the glare
    /// heuristic.
    static func glareEvidence(saturated: Double) -> FeatureTrackingDiagnostics {
        FeatureTrackingDiagnostics(
            referenceFeatures: 400, frameFeatures: 120, matchCount: 40, inlierCount: 12,
            coverage: 0.3, reprojectionError: 6, processingMilliseconds: 8,
            message: "weak match", inlierPoints: [],
            saturatedFraction: saturated, excludedHighlightFraction: 0
        )
    }
}

enum SceneProblem: Error { case noVisualQuad }

/// Drives the policy frame by frame, keeping the camera position and the clock
/// so a test reads as a sequence of events rather than index arithmetic.
struct HybridDriver {
    var alignment = HybridAlignment()
    var planes: [WorldPlane] = [HybridScene.surface(at: 0.5)]
    var position: SIMD3<Float> = .zero
    var elapsed: TimeInterval = 0
    var interval: TimeInterval = 0.15

    init(alignment: HybridAlignment = HybridAlignment(), planes: [WorldPlane]? = nil, interval: TimeInterval = 0.15) {
        self.alignment = alignment
        if let planes { self.planes = planes }
        self.interval = interval
    }

    private mutating func advance(_ offset: SIMD3<Float>) {
        position += offset
        elapsed += interval
    }

    private func snapshot(normalTracking: Bool = true, turnedBy radians: Float = 0) -> WorldCameraSnapshot {
        HybridScene.camera(at: position, turnedBy: radians, planes: planes, normalTracking: normalTracking)
    }

    /// Move, then feed the panel as it looks from there.
    @discardableResult
    mutating func step(
        by offset: SIMD3<Float> = HybridScene.sideways,
        confidence: Double = 0.9,
        normalTracking: Bool = true
    ) throws -> PanelObservation {
        advance(offset)
        let world = snapshot(normalTracking: normalTracking)
        return alignment.update(visual: try HybridScene.seen(from: world, at: elapsed, confidence: confidence),
                                world: world)
    }

    /// Move, but the visual tracker reports loss.
    @discardableResult
    mutating func stepLost(
        by offset: SIMD3<Float> = HybridScene.sideways,
        normalTracking: Bool = true
    ) throws -> PanelObservation {
        advance(offset)
        return alignment.update(
            visual: .lost(.notFound, at: HybridScene.start.addingTimeInterval(elapsed)),
            world: snapshot(normalTracking: normalTracking))
    }

    /// Move, and feed a confident match sitting `displacement` away in the image
    /// — a reflection, or the wrong rectangle.
    @discardableResult
    mutating func stepDisplaced(
        by displacement: Double = 0.06,
        saturated: Double = 0,
        offset: SIMD3<Float> = HybridScene.sideways
    ) throws -> PanelObservation {
        advance(offset)
        let world = snapshot()
        guard let truth = try HybridScene.seen(from: world, at: elapsed).quad else {
            throw SceneProblem.noVisualQuad
        }
        func shifted(_ p: ImagePoint) -> ImagePoint { ImagePoint(x: p.x + displacement, y: p.y) }
        var visual = PanelObservation.tracked(
            PanelQuad(topLeft: shifted(truth.topLeft), topRight: shifted(truth.topRight),
                      bottomRight: shifted(truth.bottomRight), bottomLeft: shifted(truth.bottomLeft)),
            confidence: 0.9,
            at: HybridScene.start.addingTimeInterval(elapsed))
        if saturated > 0 { visual.featureDiagnostics = HybridScene.glareEvidence(saturated: saturated) }
        return alignment.update(visual: visual, world: world)
    }

    /// Move, with no world snapshot at all.
    @discardableResult
    mutating func stepWithoutWorld() throws -> PanelObservation {
        advance(HybridScene.sideways)
        let world = snapshot()
        return alignment.update(visual: try HybridScene.seen(from: world, at: elapsed), world: nil)
    }

    /// Run a successful sideways calibration.
    mutating func calibrate(steps: Int = 10, step offset: SIMD3<Float> = HybridScene.sideways) throws {
        for _ in 0..<steps { try step(by: offset) }
    }
}
