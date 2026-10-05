//
//  LiveSurfaceUnderstanding.swift
//  SurfaceUnderstanding — Surface / Officers (integration)
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  REAL. This is the integration point for the three Surface stages.       │
//  │                                                                          │
//  │  1. PanelDetector    finds the panel quad and how sure it is.            │
//  │  2. ButtonDetector   finds the buttons on it.                            │
//  │  3. LabelReader      reads the text on each button.                      │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  A photo goes in; PanelDetection returns its quad, map, and photo ID — what the buttons
//  are, where they sit, how sure we are.
//
//  WHEN THE PANEL HAS NO BUTTONS ON IT
//  On real photos PanelDetector sometimes locks onto something smaller than the
//  control panel, such as the display, and there are no buttons inside that quad.
//  When that happens we look for buttons across the whole photo instead and
//  return `.fullFrame` as the quad, so the bounds stay normalized against the quad
//  we hand back. On the 18 test photos from #36 this took us from 11 to 17
//  photos with buttons found.
//
//  COORDINATES
//  The quad is in normalized coordinates of the upright REFERENCE IMAGE, not in
//  panel space — see PanelReference.swift. Button bounds are in normalized panel
//  space: (0,0) top-left, (1,1) bottom-right, y DOWNWARD, normalized against this
//  exact quad.
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

/// The real Surface pipeline: panel, then buttons, then labels.
///
/// Conforms to `ContourCore.SurfaceUnderstanding`. Fully qualified because the
/// module shares the protocol's name — see the note above.
public struct LiveSurfaceUnderstanding: ContourCore.SurfaceUnderstanding {

    public init() {}

    /// Detect controls using the returned quad for normalization. Echo photo.id.
    /// Quad corners use the full upright image before panel rectification.
    ///
    /// The map's confidence is the panel confidence from `PanelDetector`, so a
    /// caller can tell a crisp panel lock from a doubtful one. A panel with no
    /// buttons found is still a successful return with an empty map.
    ///
    /// - Throws: `SurfaceUnderstandingError`, propagated unchanged from
    ///   `PanelDetector` and `ButtonDetector` — `.undecodableImage`,
    ///   `.noPanelFound`, `.cancelled`, or `.underlying`.
    public func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        var (quad, confidence) = try await PanelDetector().detectPanel(in: photo)
        var found = try await ButtonDetector().detectButtons(in: photo, panel: quad)

        // No buttons inside the quad usually means the quad is wrong, not that
        // the panel has no buttons. Look across the whole photo instead.
        if found.isEmpty, quad != .fullFrame {
            let wholePhoto = try await ButtonDetector().detectButtons(in: photo, panel: .fullFrame)
            if !wholePhoto.isEmpty {
                quad = .fullFrame
                // The same confidence PanelDetector gives its own full-frame answer.
                confidence = min(confidence, 0.6)
                found = wholePhoto
            }
        }

        let labels = try await readLabels(in: photo, panel: quad, regions: found.map(\.bounds))

        let map = SurfaceMap(
            buttons: zip(found, labels).map { button, label in
                SurfaceMap.Button(label: label, bounds: button.bounds, confidence: button.confidence)
            },
            confidence: confidence
        )
        return PanelDetection(referencePhotoID: photo.id, quad: quad, map: map)
    }

    /// One label per region, in order.
    ///
    /// Text recognition only runs when there is something to label. If it fails,
    /// the buttons come back with `nil` labels rather than being thrown away: "there
    /// is a button here and we cannot read it" is still useful to the app.
    private func readLabels(in photo: PanelPhoto, panel: PanelQuad, regions: [PanelRect]) async throws -> [String?] {
        guard !regions.isEmpty else { return [] }

        let labels: [String?]
        do {
            labels = try await LabelReader().readLabels(in: photo, panel: panel, regions: regions)
        } catch SurfaceUnderstandingError.cancelled {
            throw SurfaceUnderstandingError.cancelled
        } catch {
            return Array(repeating: nil, count: regions.count)
        }

        // LabelReader promises one entry per region. If that ever breaks, fail
        // loudly instead of zipping labels onto the wrong buttons.
        guard labels.count == regions.count else {
            throw SurfaceUnderstandingError.underlying(
                "LabelReader returned \(labels.count) labels for \(regions.count) buttons"
            )
        }
        return labels
    }
}
