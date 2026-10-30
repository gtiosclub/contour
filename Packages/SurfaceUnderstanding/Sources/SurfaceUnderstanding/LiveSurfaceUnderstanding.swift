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
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// The real Surface pipeline: panel, then buttons, then labels.
///
/// Conforms to `ContourCore.SurfaceUnderstanding`. Fully qualified because the
/// module shares the protocol's name — see the note above.
public struct LiveSurfaceUnderstanding: ContourCore.SurfaceUnderstanding {

    private let logger = Logger(subsystem: "edu.gatech.contour", category: "SurfaceScan")

    public init() {}

    /// Detect controls using the returned quad for normalization. Echo photo.id.
    /// Quad corners use the full upright image before panel rectification.
    ///
    /// The map's confidence is the panel confidence from `PanelDetector`, so a
    /// caller can tell a crisp panel lock from a doubtful one. Once a panel is
    /// found this always returns: if buttons or labels can't be read, the map is
    /// empty or the labels are `nil`, but the panel still comes back.
    ///
    /// - Throws: `SurfaceUnderstandingError`, propagated unchanged from
    ///   `PanelDetector` — `.undecodableImage`, `.noPanelFound`, `.cancelled`, or
    ///   `.underlying` — and `.cancelled` if the task is cancelled later on.
    public func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        var (quad, confidence) = try await PanelDetector().detectPanel(in: photo)
        logger.info("Panel stage: capture=\(photo.id.uuidString, privacy: .public) pixels=\(photo.pixelSize.width)x\(photo.pixelSize.height) orientation=\(photo.orientation.rawValue, privacy: .public) fullFrame=\(quad == .fullFrame) confidence=\(confidence) quad=\(String(describing: quad), privacy: .public)")
        try checkCancellation()
        var found = try await detectButtons(in: photo, panel: quad)
        logger.info("Button stage: buttons inside initial panel=\(found.count)")

        // No buttons inside the quad usually means the quad is wrong, not that
        // the panel has no buttons. Look across the whole photo instead.
        if found.isEmpty, quad != .fullFrame {
            try checkCancellation()
            let wholePhoto = try await detectButtons(in: photo, panel: .fullFrame)
            if !wholePhoto.isEmpty {
                logger.notice("Using fullFrame fallback: initial panel contained no buttons; whole photo contains \(wholePhoto.count)")
                quad = .fullFrame
                // The same confidence PanelDetector gives its own full-frame answer.
                confidence = min(confidence, 0.6)
                found = wholePhoto
            }
        }

        let reading = try await readText(in: photo, panel: quad, regions: found.map(\.bounds))

        // A frame around several keys isn't a key; its labels come back as
        // text buttons below.
        let keys = zip(found, reading.labels).enumerated()
            .filter { !reading.frames.contains($0.offset) }
            .map { _, pair in
                SurfaceMap.Button(label: pair.1, bounds: pair.0.bounds, confidence: pair.0.confidence)
            }
        // Labels with no key outline around them are keys too on a flat
        // membrane panel. Less certain than an outlined key, so lower confidence.
        let printedOnly = Self.printedButtons(from: reading.textButtons)
        let map = SurfaceMap(buttons: keys + printedOnly, confidence: confidence)
        logger.info("Surface handoff: fullFrame=\(quad == .fullFrame) buttons=\(map.buttons.count) confidence=\(confidence)")
        return PanelDetection(referencePhotoID: photo.id, quad: quad, map: map)
    }

    /// Keep edge labels, but never guide to printed text outside the panel.
    static func printedButtons(from textButtons: [(label: String, bounds: PanelRect)]) -> [SurfaceMap.Button] {
        textButtons.filter {
            let center = $0.bounds.center
            return (-0.05...1.05).contains(center.x) && (-0.05...1.05).contains(center.y)
        }.map {
            SurfaceMap.Button(label: $0.label, bounds: $0.bounds, confidence: 0.5)
        }
    }

    /// Buttons inside `panel`. A failure here (Vision's own errors aren't
    /// `SurfaceUnderstandingError`s) means no buttons found, not no answer:
    /// the panel was already found.
    private func detectButtons(in photo: PanelPhoto, panel: PanelQuad) async throws -> [(bounds: PanelRect, confidence: Double)] {
        do {
            return try await ButtonDetector().detectButtons(in: photo, panel: panel)
        } catch {
            try checkCancellation()
            logger.error("Button detection failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// One label per region, in order, plus labels printed with no key around them.
    ///
    /// Runs even when no keys were found, because a flat membrane panel has
    /// none to find. If text recognition fails, the keys come back with `nil`
    /// labels rather than being thrown away: "there is a button here and we
    /// cannot read it" is still useful to the app.
    private func readText(in photo: PanelPhoto, panel: PanelQuad, regions: [PanelRect]) async throws -> LabelReader.Reading {
        try checkCancellation()

        let reading: LabelReader.Reading
        do {
            let input = Self.labelInput(for: photo, panel: panel)
            reading = try await LabelReader().read(in: input.photo, panel: input.panel, regions: regions)
        } catch {
            try checkCancellation()
            return LabelReader.Reading(labels: Array(repeating: nil, count: regions.count), textButtons: [])
        }

        // LabelReader promises one entry per region. If that ever breaks, fail
        // loudly instead of zipping labels onto the wrong buttons.
        guard reading.labels.count == regions.count else {
            throw SurfaceUnderstandingError.underlying(
                "LabelReader returned \(reading.labels.count) labels for \(regions.count) buttons"
            )
        }
        return reading
    }

    /// A 2x crop of the panel for LabelReader when the photo's short side is
    /// under 1000 px, with the quad moved into the crop so labels keep their
    /// panel coordinates. TIFF, since a JPEG copy lost START on microwave-07.
    /// Returns the inputs unchanged if the photo is big enough or anything fails.
    static func labelInput(for photo: PanelPhoto, panel: PanelQuad) -> (photo: PanelPhoto, panel: PanelQuad) {
        guard let image = try? photo.cgImage(),   // already upright
              min(image.width, image.height) < 1000 else { return (photo, panel) }

        // The panel's bounding box plus a 5% margin, in pixels, kept inside the photo.
        let iw = Double(image.width), ih = Double(image.height)
        let corners = [panel.topLeft, panel.topRight, panel.bottomRight, panel.bottomLeft]
        let xs = corners.map { $0.x * iw }, ys = corners.map { $0.y * ih }
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let crop = box.insetBy(dx: -0.05 * box.width, dy: -0.05 * box.height).integral
            .intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        guard !crop.isEmpty, let cropped = image.cropping(to: crop) else { return (photo, panel) }

        // Double the crop.
        let w = cropped.width * 2, h = cropped.height * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (photo, panel) }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        let data = NSMutableData()
        guard let doubled = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil)
        else { return (photo, panel) }
        CGImageDestinationAddImage(dest, doubled, nil)
        guard CGImageDestinationFinalize(dest) else { return (photo, panel) }

        // Same quad, normalized to the crop.
        func moved(_ p: ImagePoint) -> ImagePoint {
            ImagePoint(x: (p.x * iw - crop.minX) / crop.width, y: (p.y * ih - crop.minY) / crop.height)
        }
        return (PanelPhoto(data: data as Data, pixelSize: PixelSize(width: w, height: h), timestamp: photo.timestamp),
                PanelQuad(topLeft: moved(panel.topLeft), topRight: moved(panel.topRight),
                          bottomRight: moved(panel.bottomRight), bottomLeft: moved(panel.bottomLeft)))
    }
    
    /// `Task.checkCancellation()` throws `CancellationError`, which isn't part of
    /// the contract, so throw ours instead.
    private func checkCancellation() throws {
        if Task.isCancelled { throw SurfaceUnderstandingError.cancelled }
    }
}
