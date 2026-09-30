//
//  LabelReader.swift
//  SurfaceUnderstanding — Surface / Labels & Target Matching
//
//  Weeks 2–3 deliverable: "Identify basic buttons and labels" (the labels half).
//
//  Stage 3 of three. Read the text on each control.
//
//  `nil` IS A GOOD ANSWER. "There is a button here and we cannot read it" is
//  shippable — Experience announces unlabelled controls positionally ("top-left
//  button"). Guessing a label the user then presses is far worse than admitting
//  you could not read it.
//

import ContourCore
import CoreGraphics
import Foundation
import Vision

/// Stage 3 — read the labels.
public struct LabelReader: Sendable {

    public init() {}

    /// Read the text inside each of `regions` on the rectified panel.
    ///
    /// - Returns: one entry per region, in the same order. `nil` where nothing
    ///   legible was found — do not invent a label to fill a gap.
    
    
    public func readLabels(in photo: PanelPhoto, panel: PanelQuad,regions: [PanelRect])async throws -> [String?] {
        var labels = Array<String?>(repeating: nil, count: regions.count)
        
        guard let image = photo.cgImage() else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        
        let handler = VNImageRequestHandler(
            cgImage: image,
            options: [:]
        )
        try handler.perform([request])
        
        guard let observations = request.results else {
            return labels
        }
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }

            let text = candidate.string
            let box = observation.boundingBox
            
            let textRect = PanelRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            for (index, region) in regions.enumerated() {
                if region.contains(textRect.center) {
                    labels[index] = text
                    break
                }
            }
        }

        
        return labels
        
    }
    
}



