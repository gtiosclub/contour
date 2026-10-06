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
    /// Bounds must not overlap. `ContourMocks` asserts that about its canned
    /// map and the app assumes it when hit-testing.
    public func detectButtons(
        in photo: PanelPhoto,
        panel: PanelQuad
    ) async throws -> [(bounds: PanelRect, confidence: Double)] {
        let image = try photo.cgImage()

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 30
        request.minimumSize = 0.03
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0

        let panelCorners = [
            panel.topLeft,
            panel.topRight,
            panel.bottomRight,
            panel.bottomLeft
        ]

        let minX = panelCorners.map(\.x).min()!
        let maxX = panelCorners.map(\.x).max()!
        let minY = panelCorners.map(\.y).min()!
        let maxY = panelCorners.map(\.y).max()!

        let region = CGRect(
            x: minX,
            y: 1.0 - maxY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        request.regionOfInterest = region

        try VNImageRequestHandler(
            cgImage: image,
            options: [:]
        ).perform([request])

        let observations = request.results ?? []
        let detector = PanelDetector()

        var results: [(bounds: PanelRect, confidence: Double)] = []

        for observation in observations {
            let corners = [
                observation.topLeft,
                observation.topRight,
                observation.bottomRight,
                observation.bottomLeft
            ].map {
                return detector.rectify(
                    ImagePoint(
                        x: Double($0.x),
                        y: 1.0 - Double($0.y)
                    ),
                    within: panel
                )
            }

            let minX = corners.map(\.x).min()!
            let maxX = corners.map(\.x).max()!
            let minY = corners.map(\.y).min()!
            let maxY = corners.map(\.y).max()!

            let bounds = PanelRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )

            // ignore if rectangles are too large (more than half of panel)
            if bounds.width > 0.5 || bounds.height > 0.5 {
                continue
            }
            
            // ignore tiny rectangles unlikely to be buttons
            if bounds.width < 0.05 || bounds.height < 0.05 {
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

/// Removes nested boxes so each button is reported once.
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
/// instead of the key. The result doesn't depend on the order Vision returned
/// the boxes in.
private func removeOverlappingBoxes(
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

    for i in results.indices {
        for j in results.indices where isInside(j, i) {
            if results[j].confidence > results[i].confidence {
                dropped.insert(i)
            } else if results[j].confidence < results[i].confidence {
                dropped.insert(j)
            }
        }
    }

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
    return results.indices.filter { !dropped.contains($0) }.map { results[$0] }
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


// Plan (B) - Foundation Models, still in progress

//import FoundationModels
//import CoreGraphics
//import ImageIO
//
//@Generable
//struct ButtonResult {
//    @Guide(description: "Text written on the button, or nil if there is no readable text.")
//    var label: String?
//
//    @Guide(description: "Four normalized numbers [minX, minY, maxX, maxY]. 0,0 is top-left and 1,1 is bottom-right.")
//    var bounds: [Double]
//
//    @Guide(description: "Confidence from 0 to 1 that this is actually a button.")
//    var confidence: Double
//}
//
//@Generable
//struct ButtonResults {
//    @Guide(description: "Every physical button visible on the appliance control panel.")
//    var buttons: [ButtonResult]
//}
//
///// Stage 2 — find the controls.
//public struct ButtonDetector: Sendable {
//
//    public init() {}
//
//    /// Find control-shaped regions on the rectified panel.
//    ///
//    /// Returns bounds and per-region confidence only — labels come later, from
//    /// `LabelReader`. A region you are unsure about should be returned with low
//    /// confidence rather than dropped; the caller decides the threshold.
//    ///
//    /// Bounds must not overlap. `ContourMocks` asserts that about its canned
//    /// map and the app assumes it when hit-testing.
//    public func detectButtons(
//        in photo: PanelPhoto,
//        panel: PanelQuad
//    ) async throws -> [(bounds: PanelRect, confidence: Double)] {
//        guard
//            let source = CGImageSourceCreateWithData(
//                photo.data as CFData,
//                nil
//            ),
//            let image = CGImageSourceCreateImageAtIndex(
//                source,
//                0,
//                nil
//            )
//        else {
//            throw NSError(
//                domain: "ButtonDetector",
//                code: 1,
//                userInfo: [
//                    NSLocalizedDescriptionKey: "Could not decode panel image"
//                ]
//            )
//        }
//
//        let session = LanguageModelSession()
//
//        let response = try await session.respond(
//            generating: ButtonResults.self
//        ) {
//            "List every physical button in this appliance panel."
//            "For each button, return its readable label if there is one."
//            "Bounds: [minX, minY, maxX, maxY], normalized 0 to 1."
//            "(0,0) is top-left; (1,1) is bottom-right."
//
//            Attachment(image)
//        }
//        
//        // validate model response + convert to what we want to return
//        return response.content.buttons.compactMap { button in
//            guard button.bounds.count == 4 else {
//                return nil
//            }
//
//            // make sure btwn [0,1]
//            let minX = min(max(button.bounds[0], 0), 1)
//            let minY = min(max(button.bounds[1], 0), 1)
//            let maxX = min(max(button.bounds[2], 0), 1)
//            let maxY = min(max(button.bounds[3], 0), 1)
//
//            // make sure is valid rectangle
//            guard minX < maxX, minY < maxY else {
//                return nil
//            }
//
//            let rect = PanelRect(
//                x: minX,
//                y: minY,
//                width: maxX - minX,
//                height: maxY - minY
//            )
//
//            return (
//                bounds: rect,
//                confidence: button.confidence
//            )
//        }
//    }
//}
