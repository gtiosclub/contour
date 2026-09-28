//
//  LiveSurfaceUnderstanding.swift
//  SurfaceUnderstanding — Surface / Officers (integration)
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  HALF REAL. This is the integration point, not an empty room.            │
//  │                                                                          │
//  │  REAL      the panel quad and its confidence, from PanelDetector.        │
//  │  PENDING   buttons (ButtonDetector) and labels (LabelReader) are still   │
//  │            fatalError stubs, so the returned SurfaceMap has no buttons.  │
//  │                                                                          │
//  │  This does NOT call the two pending stubs — calling them would crash.    │
//  │  The commented block in detectPanel(from:) shows exactly where they      │
//  │  plug in once they land.                                                 │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  A photo goes in; PanelDetection returns its quad, map, and photo ID — what the buttons
//  are, where they sit, how sure we are.
//
//  WHAT IT CAN DELIVER TODAY
//  A real quad on a real appliance, with an empty button list. That is enough for
//  Tracking to lock onto a panel, which is what they are blocked on — they need
//  the quad and the reference photo, not the buttons. An empty SurfaceMap is a
//  successful return, not an error: "we found the panel and have not read it yet".
//
//  The app pairs this with mock buttons in ContourPipeline.realPanel() so that
//  target selection still has something to point at. That pairing lives in the
//  app target, not here — this package has no business knowing about mocks.
//
//  COORDINATES
//  The quad is in normalized coordinates of the upright REFERENCE IMAGE, not in
//  panel space — see PanelReference.swift. Button bounds, when they arrive, are
//  in normalized panel space: (0,0) top-left, (1,1) bottom-right, y DOWNWARD,
//  normalized against this exact quad.
//  See Packages/ContourCore/COORDINATES.md.
//
//  NAMING WRINKLE
//  This module is called `SurfaceUnderstanding` and so is the protocol. Inside
//  this package the bare name resolves to the module, so the conformance has to
//  be spelled `ContourCore.SurfaceUnderstanding`. Everywhere else the bare name
//  is fine.
//

import ContourCore
import Foundation

/// The real panel detector, wired as far as the stubs allow.
///
/// Conforms to `ContourCore.SurfaceUnderstanding`. Fully qualified because the
/// module shares the protocol's name — see the note above.
public struct LiveSurfaceUnderstanding: ContourCore.SurfaceUnderstanding {

    public init() {}

    /// Detect controls using the returned quad for normalization. Echo photo.id.
    /// Quad corners use the full upright image before panel rectification.
    ///
    /// Today this returns a real quad and an empty button list. The map's
    /// confidence is the panel confidence from `PanelDetector`, so a caller can
    /// already tell a crisp panel lock from a doubtful one.
    ///
    /// - Returns: a `PanelDetection` whose `quad` is real and whose `map` has no
    ///   buttons yet.
    /// - Throws: `SurfaceUnderstandingError`, propagated unchanged from
    ///   `PanelDetector` — `.undecodableImage`, `.noPanelFound`, `.cancelled`,
    ///   or `.underlying`.
    public func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        let (quad, confidence) = try await PanelDetector().detectPanel(in: photo)

        // No buttons yet. Panel confidence carries through so the caller can
        // distinguish a solid lock from a marginal one even with an empty map.
        let map = SurfaceMap(buttons: [], confidence: confidence)

        // MARK: - Pending stages
        //
        // TODO(Sanvi): ButtonDetector — find the controls on the rectified panel.
        // TODO(Srinivas): LabelReader — read the text on each control found.
        //
        // Both are fatalError stubs right now. Do NOT uncomment this until the
        // stage you own actually returns. When both land, this replaces the
        // empty `map` above and nothing else in the method changes:
        //
        //     let buttons = try await ButtonDetector()
        //         .detectButtons(in: photo, panel: quad)
        //
        //     let labels = try await LabelReader()
        //         .readLabels(in: photo, panel: quad,
        //                     regions: buttons.map { $0.bounds })
        //
        //     let map = SurfaceMap(
        //         buttons: zip(buttons, labels).map { found, label in
        //             SurfaceMap.Button(
        //                 label: label,
        //                 bounds: found.bounds,
        //                 confidence: found.confidence
        //             )
        //         },
        //         confidence: confidence
        //     )
        //
        // Two things to get right when you do:
        //
        // 1. `readLabels` promises one entry per region, in the same order, so
        //    `zip` is safe — but it is only safe because of that promise. If the
        //    two counts can ever disagree, that is a bug in LabelReader, not
        //    something to paper over here with a shorter zip.
        // 2. A `nil` label is a good answer and must survive. "There is a button
        //    here and we cannot read it" is shippable; Experience announces those
        //    positionally. Do not substitute a placeholder string.
        //
        // Landing one stage without the other is fine. Buttons with all-`nil`
        // labels are more useful than no buttons, so ButtonDetector can go live
        // first by passing `labels` as `Array(repeating: nil, count: buttons.count)`.

        return PanelDetection(referencePhotoID: photo.id, quad: quad, map: map)
    }
}
