//
//  TestSetTests.swift
//  SurfaceUnderstandingTests
//
//  Focused tests for the Eval & Test Set scoring rules.
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import SurfaceUnderstanding

@Test("the bundled corpus loads labels, panel outlines, and photos")
func bundledCorpusLoads() throws {
    let samples = try TestSet.loadSamples(from: Bundle.module)
    let photosDirectory = try #require(Bundle.module.url(
        forResource: "photos",
        withExtension: nil,
        subdirectory: "TestSet"
    ))
    let photos = try FileManager.default.contentsOfDirectory(
        at: photosDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )

    #expect(samples.count == 10)
    #expect(photos.count == 18)
    #expect(samples.first?.id == "microwave-01.jpg")
    #expect(samples.last?.id == "microwave-10.jpg")
    #expect(samples.allSatisfy { !$0.expected.buttons.isEmpty })
    #expect(samples.allSatisfy { $0.panel != .fullFrame })

    for sample in samples {
        let photo = URL(fileURLWithPath: sample.id)
        let resourceURL = Bundle.module.url(
            forResource: photo.deletingPathExtension().lastPathComponent,
            withExtension: photo.pathExtension,
            subdirectory: "TestSet/photos"
        )
        #expect(resourceURL != nil, "Missing bundled photo for \(sample.id)")
    }
}

@Test("a slightly shifted box still matches")
func shiftedBoxMatches() {
    let expected = map(label: "Start", bounds: PanelRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20))
    let detected = map(label: "  START ", bounds: PanelRect(x: 0.12, y: 0.10, width: 0.20, height: 0.20))

    let score = TestSet.score(detected: detected, against: expected)

    #expect(score.recall == 1)
    #expect(score.precision == 1)
    #expect(score.labelAccuracy == 1)
}

@Test("a box in the wrong place does not match")
func wrongPlaceDoesNotMatch() {
    let expected = map(label: "Start", bounds: PanelRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20))
    let detected = map(label: "Start", bounds: PanelRect(x: 0.70, y: 0.70, width: 0.20, height: 0.20))

    let score = TestSet.score(detected: detected, against: expected)

    #expect(score.recall == 0)
    #expect(score.precision == 0)
}

@Test("a wrong label lowers label accuracy")
func wrongLabelLowersAccuracy() {
    let bounds = PanelRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20)
    let expected = map(label: "Start", bounds: bounds)
    let detected = map(label: "Stop", bounds: bounds)

    let score = TestSet.score(detected: detected, against: expected)

    #expect(score.recall == 1)
    #expect(score.precision == 1)
    #expect(score.labelAccuracy == 0)
}

@Test("the mock microwave prints a score")
func mockMicrowavePrintsScore() {
    let expected = MockSurfaceMaps.microwave
    let detected = MockSurfaceUnderstanding().map

    let score = TestSet.score(detected: detected, against: expected)

    print("Mock microwave score — recall: \(score.recall), precision: \(score.precision), label accuracy: \(score.labelAccuracy)")
    #expect(score == SampleScore(recall: 1, precision: 1, labelAccuracy: 1))
}

private func map(label: String?, bounds: PanelRect) -> SurfaceMap {
    SurfaceMap(
        buttons: [
            SurfaceMap.Button(label: label, bounds: bounds, confidence: 1)
        ],
        confidence: 1
    )
}
