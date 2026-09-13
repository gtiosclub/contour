//
//  FingertipTracker.swift
//  Tracking — Team 2
//
//  Weeks 2–3 deliverable: "Track the index fingertip."
//
//  COORDINATES: you return normalized panel space — (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. Hand tracking gives you camera space;
//  project onto the panel and normalize here, not downstream.
//  See Packages/ContourCore/COORDINATES.md.
//
//  DO NOT CLAMP. A fingertip at y = -0.08 is above the panel, and that is real
//  information guidance depends on. Clamping to 0 lies to the user.
//

import ContourCore
import Foundation

/// Finds the user's index fingertip and places it on the panel.
public struct FingertipTracker: Sendable {

    public init() {}

    /// Locate the index fingertip for the current camera frame.
    ///
    /// - Parameter pose: where the panel is, so the fingertip can be projected
    ///   onto it. Without a pose there is no panel space to report in.
    /// - Returns: the fingertip in normalized panel space, or `nil` if no hand
    ///   was observed this frame. `nil` means "not seen" — never `(0, 0)`.
    public func fingertip(projectedOnto pose: PanelPose) async -> PanelPoint? {
        fatalError("unimplemented — owned by Team 2 (Tracking)")
    }
}
