//
//  ButtonDetector.swift
//  SurfaceUnderstanding — Surface / Panel Reader
//
//  Weeks 2–3 deliverable: "Identify basic buttons and labels" (the buttons half).
//
//  Stage 2 of three. Given a rectified panel, find the things a finger can press.
//
//  COORDINATES: bounds are in normalized panel space — (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Stage 2 — find the controls.
public struct ButtonDetector: Sendable {

    public init() {}

    /// Find control-shaped regions on the rectified panel.
    ///
    /// Returns bounds and per-region confidence only — labels come later, from
    /// `LabelReader`. A region you are unsure about should be returned with low
    /// confidence rather than dropped; the caller decides the threshold.
    ///
    /// Bounds must not overlap. `ContourMocks` asserts that about its canned
    /// map and the app assumes it when hit-testing.
    public func detectButtons(
        in photo: PanelPhoto,
        panel: PanelQuad
    ) async throws -> [(bounds: PanelRect, confidence: Double)] {
        fatalError("unimplemented — owned by Surface / Panel Reader")
    }
}
