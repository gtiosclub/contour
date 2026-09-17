//
//  PanelDetector.swift
//  SurfaceUnderstanding — Surface / Panel Reader
//
//  Weeks 2–3 deliverable: "Detect an appliance interface in a photo."
//
//  Stage 1 of three. Find the panel in the image and work out how to rectify it
//  to the unit square that everything downstream is expressed in. Get this
//  wrong and every button position is wrong by the same amount.
//
//  COORDINATES: what you return defines panel space for the whole app —
//  (0,0) top-left, (1,1) bottom-right, y DOWNWARD.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Where the panel sits in the source image, before rectification.
///
/// The four corners are in **image-relative** coordinates — fractions of the
/// image's width and height, not pixels — so that this type can cross into a
/// test without dragging a resolution along with it.
///
/// Corners are in reading order: top-left, top-right, bottom-right, bottom-left,
/// as the panel appears when upright.
public struct PanelQuad: Hashable, Sendable {
    public var topLeft: PanelPoint
    public var topRight: PanelPoint
    public var bottomRight: PanelPoint
    public var bottomLeft: PanelPoint

    public init(
        topLeft: PanelPoint,
        topRight: PanelPoint,
        bottomRight: PanelPoint,
        bottomLeft: PanelPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// The whole image, unrectified. Useful as a fallback and in tests.
    public static let fullFrame = PanelQuad(
        topLeft: PanelPoint(x: 0, y: 0),
        topRight: PanelPoint(x: 1, y: 0),
        bottomRight: PanelPoint(x: 1, y: 1),
        bottomLeft: PanelPoint(x: 0, y: 1)
    )
}

/// Stage 1 — find the panel.
public struct PanelDetector: Sendable {

    public init() {}

    /// Locate the appliance panel in `photo`.
    ///
    /// - Returns: the panel's corners and how sure we are it is a panel.
    /// - Throws: `SurfaceUnderstandingError.noPanelFound` when the image
    ///   contains nothing panel-shaped, `.undecodableImage` when it will not
    ///   decode at all.
    public func detectPanel(
        in photo: PanelPhoto
    ) async throws -> (quad: PanelQuad, confidence: Double) {
        fatalError("unimplemented — owned by Surface / Panel Reader")
    }

    /// Map a point inside `quad` onto the panel's unit square.
    ///
    /// This is the rectification step, and it is the single place where image
    /// space becomes panel space. Once you have this, nothing else in the
    /// package should think about the source image at all.
    public func rectify(_ point: PanelPoint, within quad: PanelQuad) -> PanelPoint {
        fatalError("unimplemented — owned by Surface / Panel Reader")
    }
}
