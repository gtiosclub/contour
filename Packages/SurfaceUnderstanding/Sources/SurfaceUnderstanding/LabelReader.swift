//
//  LabelReader.swift
//  SurfaceUnderstanding — Team 1
//
//  Weeks 2–3 deliverable: "Identify basic buttons and labels" (the labels half).
//
//  Stage 3 of three. Read the text on each control.
//
//  `nil` IS A GOOD ANSWER. "There is a button here and we cannot read it" is
//  shippable — Team 3 announces unlabelled controls positionally ("top-left
//  button"). Guessing a label the user then presses is far worse than admitting
//  you could not read it.
//

import ContourCore
import Foundation

/// Stage 3 — read the labels.
public struct LabelReader: Sendable {

    public init() {}

    /// Read the text inside each of `regions` on the rectified panel.
    ///
    /// - Returns: one entry per region, in the same order. `nil` where nothing
    ///   legible was found — do not invent a label to fill a gap.
    public func readLabels(
        in photo: PanelPhoto,
        panel: PanelQuad,
        regions: [PanelRect]
    ) async throws -> [String?] {
        fatalError("unimplemented — owned by Team 1 (SurfaceUnderstanding)")
    }
}
