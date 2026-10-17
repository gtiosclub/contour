//
//  GuidanceMath.swift
//  ContourMocks — Experience / Mocks & Integration
//
//  The one place the fingertip -> target geometry lives. `MockGuidance` (what
//  ContourPipeline and the Harness call today) and `MockGuidanceSource` both
//  delegate here, so the vector, the diagonal normalization and the arrival
//  check are written exactly once.
//
//  Like `MockGuidance`, this is placeholder wiring, not the guidance model:
//  no smoothing, no hysteresis, no dwell. Pure functions only.
//
//  COORDINATES: normalized panel space, (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. A target below the fingertip gives `+dy`.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Pure fingertip -> target guidance geometry.
public enum GuidanceMath {

    /// The panel's diagonal, `sqrt(2)`. `normalizedDistance` is the raw
    /// panel-space length divided by this, so `1.0` means "opposite corner".
    public static let panelDiagonal = 2.0.squareRoot()

    /// How close counts as arrived, in panel units, unless a caller says
    /// otherwise. Matches `MockGuidance`'s historical default.
    public static let defaultArrivalRadius = 0.05

    /// Guidance for one tracking frame toward the centre of `target`.
    ///
    /// - `.lost` quality, or a `nil` fingertip -> `.lostTracking`, no vector.
    /// - Within `arrivalRadius` of the centre -> `.arrived` with `.onTarget`.
    /// - Otherwise a unit direction and a distance of `length / sqrt(2)`,
    ///   **clamped to `0...1`**.
    ///
    /// The clamp is what issue #12 asks for, and it is the difference from
    /// `MockGuidance.state(for:target:)`, which keeps its historical unclamped
    /// distance (ContourCore documents that `normalizedDistance` may exceed 1
    /// off-panel, and ContourPipeline consumes MockGuidance today). With
    /// `arrivalRadius: 0` only an exact centre hit counts as arrived.
    public static func compute(
        frame: TrackingFrame,
        target: SurfaceMap.Button,
        arrivalRadius: Double = GuidanceMath.defaultArrivalRadius
    ) -> GuidanceState {
        guard frame.trackingQuality != .lost, let fingertip = frame.fingertip else {
            return .outcome(.lostTracking, at: frame.timestamp)
        }
        return state(
            from: fingertip,
            to: target.bounds.center,
            timestamp: frame.timestamp,
            arrivalRadius: arrivalRadius,
            clampsDistance: true
        )
    }

    /// Guidance from a known fingertip position to a point.
    ///
    /// - Parameters:
    ///   - clampsDistance: clamp `normalizedDistance` to `0...1`. `false`
    ///     keeps off-panel distances above 1, as `MockGuidance` always has.
    public static func state(
        from fingertip: PanelPoint,
        to target: PanelPoint,
        timestamp: Date,
        arrivalRadius: Double = GuidanceMath.defaultArrivalRadius,
        clampsDistance: Bool = true
    ) -> GuidanceState {
        let raw = fingertip.vector(to: target)
        let length = raw.magnitude

        if length <= arrivalRadius {
            return GuidanceState(timestamp: timestamp, vector: .onTarget, outcome: .arrived)
        }

        return GuidanceState(
            timestamp: timestamp,
            vector: vector(raw, clampsDistance: clampsDistance)
        )
    }

    /// Turns a raw panel-space displacement into a `GuidanceVector`.
    public static func vector(_ raw: PanelVector, clampsDistance: Bool = true) -> GuidanceVector {
        let distance = normalizedDistance(raw.magnitude)
        return GuidanceVector(
            direction: raw.normalized ?? .zero,
            normalizedDistance: clampsDistance ? min(max(distance, 0), 1) : distance
        )
    }

    /// `length / sqrt(2)`, unclamped.
    public static func normalizedDistance(_ length: Double) -> Double {
        length / panelDiagonal
    }
}
