//
//  TrackingFrame.swift
//  ContourCore
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  DRAFT — FROZEN END OF WEEK 2                                            │
//  │  Changes after the freeze require sign-off from all four team leads.     │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  Produced by: Team 2 (Tracking)
//  Consumed by: Team 3 (ContourFeedback, via GuidanceState), Team 4 (ContourUI)
//
//  `fingertip` is in NORMALIZED PANEL SPACE:
//  origin (0,0) top-left, (1,1) bottom-right, y increasing DOWNWARD.
//  See Packages/ContourCore/COORDINATES.md.
//

import Foundation

// MARK: - TrackingQuality

/// How much the rest of the app should trust a `TrackingFrame`.
public enum TrackingQuality: String, Hashable, Sendable, Codable, CaseIterable {

    /// Panel and fingertip are both locked. Guidance is safe to act on.
    case good

    /// Something is wrong — motion blur, partial occlusion, a fingertip
    /// extrapolated rather than observed — but there is still a usable estimate.
    /// Feedback should soften rather than stop.
    case degraded

    /// No usable estimate. `fingertip` is `nil` and `panel` should not be trusted.
    /// This is what drives `OutcomeSignal.lostTracking`.
    case lost
}

// MARK: - PanelPose

/// Where the panel is in space, relative to the camera, for one frame.
///
/// This is the **one** type in the contract that is not in panel space — by
/// definition, since it is what relates panel space to the physical world.
/// Team 2 owns it. Nobody else should need to read the transform; it is here so
/// that Team 4 can draw an overlay without inventing a parallel channel.
///
/// The transform is stored as four `SIMD4<Double>` columns rather than a
/// `simd_float4x4` so that the contract stays free of any framework import.
/// Convert at your package's edge.
public struct PanelPose: Hashable, Sendable, Codable {

    /// Column 0 of a column-major 4×4 rigid transform, **panel space → camera space**.
    public var column0: SIMD4<Double>
    /// Column 1 of the transform.
    public var column1: SIMD4<Double>
    /// Column 2 of the transform.
    public var column2: SIMD4<Double>
    /// Column 3 of the transform — the translation, in **metres**.
    public var column3: SIMD4<Double>

    /// How sure tracking is about this pose, `0...1`.
    ///
    /// Distinct from `SurfaceMap.confidence`, which is about detection quality in
    /// a still photo. This one is about *this frame*.
    public var confidence: Double

    public init(
        column0: SIMD4<Double>,
        column1: SIMD4<Double>,
        column2: SIMD4<Double>,
        column3: SIMD4<Double>,
        confidence: Double
    ) {
        self.column0 = column0
        self.column1 = column1
        self.column2 = column2
        self.column3 = column3
        self.confidence = confidence
    }

    /// The identity transform with zero confidence — a placeholder pose that
    /// asserts nothing. Use it in tests and mocks, not in shipping tracking.
    public static let unknown = PanelPose(
        column0: SIMD4(1, 0, 0, 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0),
        column3: SIMD4(0, 0, 0, 1),
        confidence: 0
    )

    /// The panel's translation relative to the camera, in metres.
    public var translation: SIMD3<Double> {
        SIMD3(column3.x, column3.y, column3.z)
    }
}

// MARK: - TrackingFrame

/// One frame of spatial state: where the panel is, where the finger is, and how
/// much to trust either.
///
/// Frames arrive on a `TrackingSource` stream at camera rate. They are values —
/// a consumer may keep one, drop one, or coalesce a burst without asking anyone.
///
/// `fingertip` is in normalized panel space: `(0, 0)` top-left, `(1, 1)`
/// bottom-right, `y` increasing downward. See `COORDINATES.md`.
public struct TrackingFrame: Hashable, Sendable, Codable {

    /// When this frame was observed.
    ///
    /// Used for staleness checks and for ordering. Consumers must tolerate
    /// duplicate and slightly out-of-order timestamps; cameras are not clocks.
    public var timestamp: Date

    /// Where the user's fingertip is on the panel, in normalized panel space.
    ///
    /// `nil` means no fingertip was observed this frame — out of view, occluded,
    /// or tracking is `.lost`. It does **not** mean "at the origin". Values
    /// outside `0...1` mean the finger is off the panel's edge, which is real
    /// information: guidance needs it to say "left and up".
    public var fingertip: PanelPoint?

    /// Where the panel is relative to the camera, and how sure we are.
    public var panel: PanelPose

    /// How much to trust this frame overall.
    public var trackingQuality: TrackingQuality

    public init(
        timestamp: Date,
        fingertip: PanelPoint?,
        panel: PanelPose,
        trackingQuality: TrackingQuality
    ) {
        self.timestamp = timestamp
        self.fingertip = fingertip
        self.panel = panel
        self.trackingQuality = trackingQuality
    }

    /// A frame that asserts nothing: no fingertip, unknown pose, `.lost`.
    ///
    /// Emit this rather than skipping a frame when tracking drops, so consumers
    /// see the loss instead of silence.
    public static func lost(at timestamp: Date) -> TrackingFrame {
        TrackingFrame(
            timestamp: timestamp,
            fingertip: nil,
            panel: .unknown,
            trackingQuality: .lost
        )
    }
}
