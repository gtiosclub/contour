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

    /// Every number behind the arrival oval, in panel units, so they can be tuned
    /// on a real microwave in one place. Guesses from one microwave, simulated
    /// only; rough multi-step branch, not for merging.
    ///
    /// The other numbers that decide arrival live in ContourFeedback, which can't
    /// see this package: the 0.01 dead zone (`deadZone` in
    /// ExperienceDirectionInstruction.swift, where "Move slowly" replaces a
    /// direction), and the 1.25 s hold and 0.5 s dropout limit (`duration` and
    /// `maximumDropout` in GuidanceArrivalHold.swift). The dead zone is per axis
    /// and in panel diagonals, so 0.01 is a square of 0.014 panel units either side
    /// of the center. Where that square pokes out of a small oval (both half-sizes
    /// under about 0.02), a finger just outside the oval hears "Move slowly" with
    /// no direction to follow.
    public enum ArrivalTuning {
        /// Each half of the oval as a share of the key's width or height. Under
        /// 0.5, a key's oval stays inside the key and off its neighbour's center.
        public static let share = 0.45
        /// The smallest half-size, so a thin word box is still holdable.
        public static let floor = 0.015
        /// The largest half-sizes, so an oversized box can't swallow the panel.
        public static let widthCap = 0.12
        public static let heightCap = 0.05
    }

    /// Half-sizes of the oval that counts as arrived on `button`, in panel units.
    /// See `ArrivalTuning`.
    public static func arrivalZone(for button: SurfaceMap.Button) -> (x: Double, y: Double) {
        (x: min(max(ArrivalTuning.share * button.bounds.width, ArrivalTuning.floor), ArrivalTuning.widthCap),
         y: min(max(ArrivalTuning.share * button.bounds.height, ArrivalTuning.floor), ArrivalTuning.heightCap))
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
