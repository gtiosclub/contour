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

@Test("Labels: read through the real quad when the panel doesn't fill the photo")
func labelReaderUsesTheQuad() async throws {
    let (photo, quad) = try SyntheticPanel.insetPhoto()
    let regions = SyntheticPanel.expected.buttons.map(\.bounds)

    let labels = try await LabelReader().readLabels(in: photo, panel: quad, regions: regions)

    #expect(labels.map { $0?.lowercased() } == SyntheticPanel.expected.buttons.map { $0.label?.lowercased() })
}

@Test("Labels: labels close together on one row each go to their own button")
func labelReaderSplitsAMergedLine() async throws {
    let (photo, regions, expected) = try SyntheticPanel.tightRowPhoto()

    let labels = try await LabelReader().readLabels(in: photo, panel: .fullFrame, regions: regions)

    // Vision reads this row as "Popcorn Beverage Defrost". Assigning that whole
    // line by its centre would give [nil, "Popcorn Beverage Defrost", nil].
    #expect(labels.map { $0?.lowercased() } == expected.map { $0.lowercased() })
}
