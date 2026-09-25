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
import Foundation
import Vision
import ImageIO

/// Stage 3 — read the labels.
public struct LabelReader: Sendable {

    public init() {}

    /// Read the text inside each of `regions` on the rectified panel.
    ///
    /// - Returns: one entry per region, in the same order. `nil` where nothing
    ///   legible was found — do not invent a label to fill a gap.
    
    
    public func readLabels(in photo: PanelPhoto, panel: PanelQuad,regions: [PanelRect])async throws -> [(String,CGRect)]? {
        
        var labels = [(String,CGRect)]()
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else {
                    continue
                }

                let text = candidate.string
                let box = observation.boundingBox

                print("Text: \(text)")
                print("Vision box: \(box)")
                let singleLabel = (text,box)
                labels.append(singleLabel)
                
            }

        }
        request.recognitionLevel = .accurate
        try handler.perform([request])

        return labels
    }
    
}
