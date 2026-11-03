//
//  MockGuidance.swift
//  ContourMocks — Experience / Mocks & Integration
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  PLACEHOLDER WIRING — NOT ANYBODY'S FEATURE                              │
//  │                                                                          │
//  │  Something has to turn a TrackingFrame plus a chosen target into the     │
//  │  GuidanceState that FeedbackEngine consumes, or the Harness has nothing  │
//  │  to emit and ContourApp has nothing to wire. This is the smallest thing  │
//  │  that does it: subtract two points, normalize, check for arrival.        │
//  │                                                                          │
//  │  It is deliberately naive. There is no smoothing, no hysteresis, no      │
//  │  dwell time, no confidence gating beyond the crudest check. Whoever ends │
//  │  up owning the real pipeline replaces this outright — it lives in        │
//  │  ContourMocks precisely so that deleting it breaks nothing but mocks.    │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  COORDINATES: normalized panel space, (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Placeholder composition of `TrackingFrame` + target into `GuidanceState`.
///
/// Pure and deterministic: no state, no clock, no randomness.
public enum MockGuidance {

    /// The panel's diagonal, which is what `normalizedDistance` is measured
    /// against so that `1.0` means "opposite corner".
    public static let panelDiagonal = 2.0.squareRoot()

    /// Guidance for a fingertip heading toward a point.
    ///
    /// - Parameters:
    ///   - fingertip: current fingertip position, or `nil` if unobserved.
    ///   - target: where the fingertip should end up.
    ///   - timestamp: stamped onto the returned state.
    ///   - arrivalRadius: how close counts as arrived, in panel units.
    public static func state(
        fingertip: PanelPoint?,
        target: PanelPoint,
        timestamp: Date,
        arrivalRadius: Double = 0.05
    ) -> GuidanceState {
        guard let fingertip else {
            return GuidanceState(timestamp: timestamp, vector: nil)
        }

        let raw = fingertip.vector(to: target)
        let distance = raw.magnitude

        if distance <= arrivalRadius {
            return GuidanceState(
                timestamp: timestamp,
                vector: .onTarget,
                outcome: .arrived
            )
        }

        return GuidanceState(
            timestamp: timestamp,
            vector: GuidanceVector(
                direction: raw.normalized ?? .zero,
                normalizedDistance: distance / panelDiagonal
            )
        )
    }

    /// Half-sizes of the oval that counts as arrived on `button`, in panel units:
    /// 45% of each side, so a key's zone stays inside the key and a neighbour's
    /// center stays out of it. The floor keeps a thin word box holdable and the
    /// cap stops an oversized box swallowing the panel. Guesses from one
    /// microwave, simulated only; rough multi-step branch, not for merging.
    public static func arrivalZone(for button: SurfaceMap.Button) -> (x: Double, y: Double) {
        (x: min(max(0.45 * button.bounds.width, 0.015), 0.12),
         y: min(max(0.45 * button.bounds.height, 0.015), 0.05))
    }

    /// Whether `fingertip` is inside `button`'s arrival oval.
    public static func isInArrivalZone(_ fingertip: PanelPoint, of button: SurfaceMap.Button) -> Bool {
        let zone = arrivalZone(for: button)
        let offset = fingertip.vector(to: button.bounds.center)
        return (offset.dx / zone.x) * (offset.dx / zone.x) + (offset.dy / zone.y) * (offset.dy / zone.y) <= 1
    }

    /// Guidance for one tracking frame heading toward a button.
    ///
    /// Maps the two tracking failure modes onto outcomes: `.lost` quality
    /// becomes `.lostTracking`, and a panel we can barely see becomes
    /// `.lowConfidence`.
    public static func state(
        for frame: TrackingFrame,
        target: SurfaceMap.Button,
        confidenceFloor: Double = 0.3
    ) -> GuidanceState {
        if frame.trackingQuality == .lost {
            return .outcome(.lostTracking, at: frame.timestamp)
        }

        if frame.panel.confidence < confidenceFloor {
            return .outcome(.lowConfidence, at: frame.timestamp)
        }

        if let fingertip = frame.fingertip, isInArrivalZone(fingertip, of: target) {
            return GuidanceState(timestamp: frame.timestamp, vector: .onTarget, outcome: .arrived)
        }

        return state(
            fingertip: frame.fingertip,
            target: target.bounds.center,
            timestamp: frame.timestamp,
            arrivalRadius: 0
        )
    }
}
