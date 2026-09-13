//
//  SurfaceMap.swift
//  ContourCore
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  DRAFT — FROZEN END OF WEEK 2                                            │
//  │  Changes after the freeze require sign-off from all four team leads.     │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  Produced by: Team 1 (SurfaceUnderstanding)
//  Consumed by: Team 4 (ContourUI, target selection), Team 2 (Tracking, to know
//               what it is tracking against).
//
//  All geometry here is in NORMALIZED PANEL SPACE:
//  origin (0,0) top-left, (1,1) bottom-right, y increasing DOWNWARD.
//  See Packages/ContourCore/COORDINATES.md.
//

import Foundation

/// Everything Contour understands about one control panel, from one photo.
///
/// A `SurfaceMap` is a still, stateless description: it says what buttons exist
/// and where they sit on the panel's unit square. It says nothing about where
/// the panel is in the room, where the user's finger is, or what happens next —
/// that is `TrackingFrame`'s job.
///
/// Geometry is in normalized panel space: `(0, 0)` top-left, `(1, 1)`
/// bottom-right, `y` increasing downward. See `COORDINATES.md`.
public struct SurfaceMap: Hashable, Sendable, Codable {

    /// One control on the panel.
    ///
    /// `bounds` is in normalized panel space — `(0, 0)` top-left, `y` down.
    /// See `COORDINATES.md`.
    public struct Button: Identifiable, Hashable, Sendable, Codable {

        /// Stable identity for this button within its `SurfaceMap`.
        ///
        /// Identity is per-map: re-running detection on a new photo produces new
        /// ids. Nothing may assume an id survives a re-scan.
        public let id: UUID

        /// The text on the button, if it could be read.
        ///
        /// `nil` means "there is a control here but we could not read it" — which
        /// is a useful, shippable result, not a failure. Team 3 announces
        /// unlabelled buttons positionally ("top-left button").
        public var label: String?

        /// The button's extent on the panel, in normalized panel space.
        ///
        /// `bounds.center` is the point guidance steers the fingertip toward.
        public var bounds: PanelRect

        /// How sure detection is about *this button*, `0...1`.
        ///
        /// Independent of `SurfaceMap.confidence`: a confidently-detected panel
        /// can still contain one smudged button.
        public var confidence: Double

        public init(
            id: UUID = UUID(),
            label: String?,
            bounds: PanelRect,
            confidence: Double
        ) {
            self.id = id
            self.label = label
            self.bounds = bounds
            self.confidence = confidence
        }
    }

    /// The controls found on the panel.
    ///
    /// Order is not meaningful — do not assume reading order. Sort by
    /// `bounds.origin` if you need a stable presentation order.
    public var buttons: [Button]

    /// How sure detection is that this is a control panel at all, `0...1`.
    ///
    /// Low panel confidence with high per-button confidence usually means
    /// "we found buttons on something, but it may not be the appliance you meant".
    /// That is the case `OutcomeSignal.lowConfidence` exists for.
    public var confidence: Double

    public init(buttons: [Button], confidence: Double) {
        self.buttons = buttons
        self.confidence = confidence
    }

    /// A map with no buttons and zero confidence.
    public static let empty = SurfaceMap(buttons: [], confidence: 0)

    /// The button whose bounds contain `point`, if any.
    ///
    /// If bounds overlap, the first match in `buttons` order wins. Detection is
    /// expected not to emit overlapping bounds.
    public func button(at point: PanelPoint) -> Button? {
        buttons.first { $0.bounds.contains(point) }
    }

    /// The button whose label matches `label`, case- and diacritic-insensitively.
    ///
    /// This is a convenience for demos and tests. Real voice-driven lookup —
    /// "the popcorn one", "third from the left" — is Team 4's problem, not the
    /// contract's.
    public func button(labelled label: String) -> Button? {
        buttons.first {
            guard let candidate = $0.label else { return false }
            return candidate.compare(
                label,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }
}
