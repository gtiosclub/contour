//
//  PanelPhoto.swift
//  ContourCore
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  DRAFT — FROZEN END OF WEEK 2                                            │
//  │  Changes after the freeze require sign-off from all four team leads.     │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  Produced by: Experience (ContourUI, capture)
//  Consumed by: Surface Understanding (SurfaceUnderstanding)
//
//  The handoff from "the user took a picture" to "what is on this panel".
//  See Packages/ContourCore/COORDINATES.md for how the answer comes back.
//

import Foundation

/// How the image is rotated relative to upright.
///
/// A deliberately small subset: the four right-angle rotations. Mirrored and
/// flipped orientations are not produced by our capture path, so they are not in
/// the contract. Surface Understanding normalizes to upright before detection;
/// everything that leaves that package is in upright panel space regardless of
/// this value.
public enum PhotoOrientation: String, Hashable, Sendable, Codable, CaseIterable {
    case up
    case right
    case down
    case left
}

/// A still photo of a control panel, on its way to detection.
///
/// Encoded bytes rather than a `UIImage` or a `CVPixelBuffer` so that the
/// contract compiles on every platform — including the macOS `Harness`, which
/// has no camera and no UIKit. Decode at your package's edge.
public struct PanelPhoto: Hashable, Sendable, Codable {

    /// The encoded image — HEIC or JPEG as the capture path produced it.
    public var data: Data

    /// The image's dimensions in pixels.
    ///
    /// Metadata only. This is a *size*, never a *position*: no pixel coordinate
    /// crosses a package boundary in Contour. See rule 5 in `COORDINATES.md`.
    public var pixelSize: PixelSize

    /// How the image is rotated relative to upright.
    public var orientation: PhotoOrientation

    /// When the photo was taken.
    public var timestamp: Date

    public init(
        data: Data,
        pixelSize: PixelSize,
        orientation: PhotoOrientation = .up,
        timestamp: Date
    ) {
        self.data = data
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.timestamp = timestamp
    }
}

/// Why detection could not produce a `SurfaceMap`.
///
/// Thrown by `SurfaceUnderstanding.surfaceMap(from:)`. Note that "we found a
/// panel but we are not sure" is **not** an error — that is a low-confidence
/// `SurfaceMap`, and the caller decides whether to surface
/// `OutcomeSignal.lowConfidence`. Errors are for "there is no answer at all".
public enum SurfaceUnderstandingError: Error, Hashable, Sendable {

    /// The image could not be decoded.
    case undecodableImage

    /// The image decoded fine but contains nothing panel-shaped.
    case noPanelFound

    /// Detection was cancelled before it finished.
    case cancelled

    /// Anything else, with a human-readable reason for the log.
    case underlying(String)
}
