//
//  LabelReader.swift
//  SurfaceUnderstanding — Surface / Labels
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
        
        let image = try photo.cgImage()
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        
        let handler = VNImageRequestHandler(
            cgImage: image,
            options: [:]
        )
        try handler.perform([request])
        
        let observations = request.results ?? []
        
        let detector = PanelDetector()
        
        for(index,region) in regions.enumerated() {
            var regionLabels: [(text: String, point: PanelPoint)] = []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else {
                    continue
                }
                
                let box = observation.boundingBox
                
                let imagePoint = ImagePoint(
                    x: box.midX,
                    y: 1 - box.midY
                )
                
                let panelPoint = detector.rectify(
                    imagePoint,
                    within: panel
                )
                
                if region.contains(panelPoint) {
                    regionLabels.append(
                        (text: candidate.string, point: panelPoint)
                    )
                }
                if !regionLabels.isEmpty {
                    regionLabels.sort {
                        if $0.point.y != $1.point.y {
                            return $0.point.y < $1.point.y
                        }
                        return $0.point.x < $1.point.x
                    }
                    
                    labels[index] = regionLabels
                        .map { $0.text }
                        .joined(separator: " ")
                }
            }
            
            
            
        }
        return labels
    }
    
}
