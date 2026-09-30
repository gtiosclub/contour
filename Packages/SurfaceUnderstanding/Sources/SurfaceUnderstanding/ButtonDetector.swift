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
                detector.rectify(
                    ImagePoint(x: Double($0.x), y: 1.0 - Double($0.y)),
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

/// Removes boxes that overlap another box (at least 50% of smaller box is covered by larger box).
///
/// If one box is mostly inside another, keep the higher-confidence box.
/// If confidence is equal, keep the larger box.

private func removeOverlappingBoxes(
    _ results: [(bounds: PanelRect, confidence: Double)]
) -> [(bounds: PanelRect, confidence: Double)] {
    var kept: [(bounds: PanelRect, confidence: Double)] = []

    for candidate in results {
        var shouldKeep = true
        var indexesToRemove: [Int] = []

        for (index, existing) in kept.enumerated() {
            let overlap = overlapRatio(
                candidate.bounds,
                existing.bounds
            )

            if overlap >= 0.5 {
                if candidate.confidence > existing.confidence {
                    indexesToRemove.append(index)
                } else if candidate.confidence == existing.confidence {
                    let candidateArea =
                        candidate.bounds.width * candidate.bounds.height
                    let existingArea =
                        existing.bounds.width * existing.bounds.height

                    if candidateArea > existingArea {
                        indexesToRemove.append(index)
                    } else {
                        shouldKeep = false
                        break
                    }
                } else {
                    shouldKeep = false
                    break
                }
            }
        }

        if shouldKeep {
            for index in indexesToRemove.reversed() {
                kept.remove(at: index)
            }
            kept.append(candidate)
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
