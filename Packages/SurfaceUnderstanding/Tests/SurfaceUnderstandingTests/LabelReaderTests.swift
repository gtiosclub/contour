//
//  LabelReaderTests.swift
//  SurfaceUnderstandingTests — Surface / Labels
//
//  The two cases the lane test can't see: a panel that doesn't fill the photo,
//  and labels close enough together that Vision reads them as one line.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

@Test("Labels: read through the real quad when the panel doesn't fill the photo",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func labelReaderUsesTheQuad() async throws {
    let (photo, quad) = try SyntheticPanel.insetPhoto()
    let regions = SyntheticPanel.expected.buttons.map(\.bounds)

    let labels = try await LabelReader().readLabels(in: photo, panel: quad, regions: regions)

    let expected = SyntheticPanel.expected.buttons.map(\.label)
    #expect(TextRecognitionCheck.labelsMatch(labels, expected), "read \(labels), expected \(expected)")
}

@Test("Labels: labels close together on one row each go to their own button",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func labelReaderSplitsAMergedLine() async throws {
    let (photo, regions, expected) = try SyntheticPanel.tightRowPhoto()

    let labels = try await LabelReader().readLabels(in: photo, panel: .fullFrame, regions: regions)

    // Vision reads this row as "Popcorn Beverage Defrost". Assigning that whole
    // line by its centre would give [nil, "Popcorn Beverage Defrost", nil].
    #expect(TextRecognitionCheck.labelsMatch(labels, expected), "read \(labels), expected \(expected)")
}
