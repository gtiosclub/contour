//
//  ButtonDetector.swift
//  SurfaceUnderstanding — Surface / Button Detector
//
//  Weeks 2–3 deliverable: "Identify basic buttons and labels" (the buttons half).
//
//  Stage 2 of three. Given a rectified panel, find the things a finger can press.
//
//  COORDINATES: bounds are in normalized panel space — (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import CoreImage
import Foundation
import Vision

/// Stage 2 — find the controls.
public struct ButtonDetector: Sendable {

    public init() {}

    /// Find control-shaped regions on the rectified panel.
    ///
    /// Returns bounds and per-region confidence only — labels come later, from
    /// `LabelReader`. A region you are unsure about should be returned with low
    /// confidence rather than dropped; the caller decides the threshold.
    ///
    /// If the given panel quad is incorrect, such as covering only the clock
    /// display, returning no buttons is correct. `LiveSurfaceUnderstanding` can
    /// then fall back to searching the whole photo.
    ///
    /// Returned bounds must not overlap. Partial overlaps are trimmed after
    /// nested boxes are removed. `ContourMocks` asserts this about its canned
    /// map, and the app assumes it when hit-testing.
    public func detectButtons(
        in photo: PanelPhoto,
        panel: PanelQuad
    ) async throws -> [(bounds: PanelRect, confidence: Double)] {
        let sourceImage = try photo.cgImage()
        let image = try panel == .fullFrame
            ? sourceImage
            : straighten(sourceImage, panel: panel)

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 30
        request.minimumSize = 0.03
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let observations = request.results ?? []

        var results: [(bounds: PanelRect, confidence: Double)] = []

        for observation in observations {
            let bounds: PanelRect
            if panel == .fullFrame {
                let corners = [
                    observation.topLeft,
                    observation.topRight,
                    observation.bottomRight,
                    observation.bottomLeft
                ]
                let minX = corners.map(\.x).min()!
                let maxX = corners.map(\.x).max()!
                let minY = corners.map { 1.0 - $0.y }.min()!
                let maxY = corners.map { 1.0 - $0.y }.max()!
                bounds = PanelRect(
                    x: Double(minX),
                    y: Double(minY),
                    width: Double(maxX - minX),
                    height: Double(maxY - minY)
                )
            } else {
                bounds = PanelRect(
                    x: Double(observation.boundingBox.minX),
                    y: 1.0 - Double(observation.boundingBox.maxY),
                    width: Double(observation.boundingBox.width),
                    height: Double(observation.boundingBox.height)
                )
            }

            // ignore if rectangles are too large (more than half of panel)
            if bounds.width > 0.5 || bounds.height > 0.5 {
                continue
            }

            // A straightened display can make each digit look like a tall
            // button-shaped rectangle. Physical keys in this detector are
            // wider than they are tall; reject those display glyphs.
            if bounds.height > bounds.width * 2 {
                continue
            }
            
            // ignore if centers are outside the panel
            if !bounds.center.isOnPanel {
                continue
            }

            results.append(
                (
                    bounds: bounds,
                    confidence: Double(observation.confidence)
                )
            )
        }
        return removeOverlappingBoxes(results)
    }
}

private func straighten(_ image: CGImage, panel: PanelQuad) throws -> CGImage {
    let input = CIImage(cgImage: image)
    guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
        throw SurfaceUnderstandingError.underlying("Perspective correction is unavailable")
    }

    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    func vector(_ point: ImagePoint) -> CIVector {
        CIVector(x: CGFloat(point.x) * width, y: (1 - CGFloat(point.y)) * height)
    }

    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(vector(panel.topLeft), forKey: "inputTopLeft")
    filter.setValue(vector(panel.topRight), forKey: "inputTopRight")
    filter.setValue(vector(panel.bottomRight), forKey: "inputBottomRight")
    filter.setValue(vector(panel.bottomLeft), forKey: "inputBottomLeft")

    guard
        let output = filter.outputImage,
        let corrected = CIContext(options: [.useSoftwareRenderer: true])
            .createCGImage(output, from: output.extent)
    else {
        throw SurfaceUnderstandingError.underlying("Perspective correction failed")
    }
    return corrected
}

/// Removes nested boxes and trims remaining overlaps so each button is reported once.
///
/// Vision finds rectangles at several levels: a plate or frame around a group of
/// keys, each key, and sometimes the text or icon printed on a key. Two boxes are
/// nested when at least half of the smaller one is inside the larger one.
///
/// If their confidences differ, the more confident box wins, as before. But
/// Vision gives almost every rectangle a confidence of 1.0, so usually it comes
/// down to what the inner boxes cover:
/// - if they fill at least half of the outer box, the outer box is a frame
///   around keys, so it's dropped and the keys stay;
/// - otherwise they're details printed on one key, so the key stays and they're
///   dropped.
/// Neither "keep the larger" nor "keep the smaller" works on its own: the first
/// lets a frame swallow the keys inside it, the second keeps a key's text
/// instead of the key. Remaining overlaps are trimmed at their shared midpoint.
func removeOverlappingBoxes(
    _ results: [(bounds: PanelRect, confidence: Double)]
) -> [(bounds: PanelRect, confidence: Double)] {
    func area(_ i: Int) -> Double {
        results[i].bounds.width * results[i].bounds.height
    }

    // Box `j` sits inside box `i`. The index breaks exact ties, so two copies
    // of the same rectangle collapse to one.
    func isInside(_ j: Int, _ i: Int) -> Bool {
        guard j != i else { return false }

        guard area(j) < area(i) || (area(j) == area(i) && j > i) else { return false }

        guard overlapRatio(results[j].bounds, results[i].bounds) >= 0.5 else { return false }

        let center = results[j].bounds.center

        let iBounds = results[i].bounds
        let centerIsInside =
            center.x >= iBounds.origin.x &&
            center.x <= iBounds.origin.x + iBounds.width &&
            center.y >= iBounds.origin.y &&
            center.y <= iBounds.origin.y + iBounds.height

        return centerIsInside
    }

    var dropped = Set<Int>()

    // The more confident of two nested boxes wins outright.
    for i in results.indices {
        for j in results.indices where isInside(j, i) {
            if results[j].confidence > results[i].confidence {
                dropped.insert(i)
            } else if results[j].confidence < results[i].confidence {
                dropped.insert(j)
            }
        }
    }

    // Equal confidence: decide by how much of the outer box the inner ones fill.
    var frames = Set<Int>()
    var details = Set<Int>()
    for i in results.indices where !dropped.contains(i) {
        let inner = results.indices.filter {
            !dropped.contains($0) && isInside($0, i)
                && results[$0].confidence == results[i].confidence
        }
        if inner.isEmpty { continue }

        let nonNestedInner = inner.filter { j in
            !inner.contains { k in
                k != j && isInside(j, k)
            }
        }

        let filled = nonNestedInner.map(area).reduce(0, +)

        if filled >= 0.5 * area(i) {
            frames.insert(i)
        } else {
            details.formUnion(inner)
        }
    }

    dropped.formUnion(frames)
    dropped.formUnion(details)

    var kept = results.indices
        .filter { !dropped.contains($0) }
        .map { results[$0] }

    var changed = true

    while changed {
        changed = false

        for i in kept.indices {
            for j in kept.indices where j > i {
                let first = kept[i].bounds
                let second = kept[j].bounds

                let overlapWidth = min(first.maxX, second.maxX)
                    - max(first.minX, second.minX)
                let overlapHeight = min(first.maxY, second.maxY)
                    - max(first.minY, second.minY)

                guard overlapWidth > 0, overlapHeight > 0 else {
                    continue
                }

                let firstConfidence = kept[i].confidence
                let secondConfidence = kept[j].confidence

                if overlapWidth <= overlapHeight {
                    let midpoint = (
                        max(first.origin.x, second.origin.x)
                        + min(first.maxX, second.maxX)
                    ) / 2

                    let firstCenterX = first.origin.x + first.width / 2
                    let secondCenterX = second.origin.x + second.width / 2

                    if firstCenterX <= secondCenterX {
                        kept[i] = (
                            bounds: PanelRect(
                                x: first.origin.x,
                                y: first.origin.y,
                                width: midpoint - first.origin.x,
                                height: first.height
                            ),
                            confidence: firstConfidence
                        )

                        kept[j] = (
                            bounds: PanelRect(
                                x: kept[i].bounds.maxX,
                                y: second.origin.y,
                                width: second.maxX - kept[i].bounds.maxX,
                                height: second.height
                            ),
                            confidence: secondConfidence
                        )
                    } else {
                        var secondBounds = second
                        secondBounds.width = midpoint - second.minX
                        kept[j].bounds = secondBounds

                        var firstBounds = first
                        firstBounds.origin.x = kept[j].bounds.maxX
                        firstBounds.width = first.maxX - firstBounds.minX
                        kept[i].bounds = firstBounds
                    }
                } else {
                    // Trim vertically
                    let midpoint = (
                        max(first.origin.y, second.origin.y)
                        + min(first.maxY, second.maxY)
                    ) / 2

                    let firstCenterY = first.origin.y + first.height / 2
                    let secondCenterY = second.origin.y + second.height / 2

                    if firstCenterY <= secondCenterY {
                        kept[i] = (
                            bounds: PanelRect(
                                x: first.origin.x,
                                y: first.origin.y,
                                width: first.width,
                                height: midpoint - first.origin.y
                            ),
                            confidence: firstConfidence
                        )

                        kept[j] = (
                            bounds: PanelRect(
                                x: second.origin.x,
                                y: kept[i].bounds.maxY,
                                width: second.width,
                                height: second.maxY - kept[i].bounds.maxY
                            ),
                            confidence: secondConfidence
                        )
                    } else {
                        var secondBounds = second
                        secondBounds.height = midpoint - second.minY
                        kept[j].bounds = secondBounds

                        var firstBounds = first
                        firstBounds.origin.y = kept[j].bounds.maxY
                        firstBounds.height = first.maxY - firstBounds.minY
                        kept[i].bounds = firstBounds
                    }
                }

                changed = true
            }
        }
    }

    return kept
}

/// Returns the intersection area divided by the area of the smaller box.
private func overlapRatio(
    _ first: PanelRect,
    _ second: PanelRect
) -> Double {
    let firstMinX = first.origin.x
    let firstMaxX = first.origin.x + first.width
    let firstMinY = first.origin.y
    let firstMaxY = first.origin.y + first.height

    let secondMinX = second.origin.x
    let secondMaxX = second.origin.x + second.width
    let secondMinY = second.origin.y
    let secondMaxY = second.origin.y + second.height

    let intersectionWidth = max(
        0,
        min(firstMaxX, secondMaxX) - max(firstMinX, secondMinX)
    )

    let intersectionHeight = max(
        0,
        min(firstMaxY, secondMaxY) - max(firstMinY, secondMinY)
    )

    let intersectionArea =
        intersectionWidth * intersectionHeight

    let firstArea = first.width * first.height
    let secondArea = second.width * second.height
    let smallerArea = min(firstArea, secondArea)

    guard smallerArea > 0 else {
        return 0
    }
    return intersectionArea / smallerArea
}
