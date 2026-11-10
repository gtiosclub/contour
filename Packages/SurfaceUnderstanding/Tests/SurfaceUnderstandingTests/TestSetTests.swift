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

@Test("scoreboard mapping leaves a box unchanged when the quads match")
func scoreboardMappingIdentity() {
    let quad = PanelQuad(
        topLeft: ImagePoint(x: 0.12, y: 0.18),
        topRight: ImagePoint(x: 0.86, y: 0.11),
        bottomRight: ImagePoint(x: 0.91, y: 0.88),
        bottomLeft: ImagePoint(x: 0.08, y: 0.79)
    )
    let original = PanelRect(x: 0.17, y: 0.29, width: 0.31, height: 0.23)

    let mapped = TestSet.bounds(original, from: quad, to: quad)

    expectEqual(mapped, original)
}

@Test("scoreboard mapping moves a full-frame photo point into the labelled panel")
func scoreboardMappingFullFrameToLabelledPanel() {
    let labelled = rectangularQuad(minX: 0.25, minY: 0.2, maxX: 0.75, maxY: 0.6)
    let point = PanelRect(x: 0.5, y: 0.4, width: 0, height: 0)

    let mapped = TestSet.bounds(point, from: .fullFrame, to: labelled)

    expectEqual(mapped, PanelRect(x: 0.5, y: 0.5, width: 0, height: 0))
}

@Test("scoreboard mapping through two skewed quads matches direct rectification")
func scoreboardMappingSkewedQuads() {
    let detected = PanelQuad(
        topLeft: ImagePoint(x: 0.08, y: 0.13),
        topRight: ImagePoint(x: 0.79, y: 0.04),
        bottomRight: ImagePoint(x: 0.92, y: 0.83),
        bottomLeft: ImagePoint(x: 0.19, y: 0.94)
    )
    let labelled = PanelQuad(
        topLeft: ImagePoint(x: 0.21, y: 0.09),
        topRight: ImagePoint(x: 0.88, y: 0.22),
        bottomRight: ImagePoint(x: 0.76, y: 0.91),
        bottomLeft: ImagePoint(x: 0.11, y: 0.72)
    )
    let photoPoint = ImagePoint(x: 0.57, y: 0.46)
    let detector = PanelDetector()
    let inDetected = detector.rectify(photoPoint, within: detected)
    let box = PanelRect(x: inDetected.x, y: inDetected.y, width: 0, height: 0)
    let direct = detector.rectify(photoPoint, within: labelled)

    let mapped = TestSet.bounds(box, from: detected, to: labelled)

    expectEqual(mapped, PanelRect(x: direct.x, y: direct.y, width: 0, height: 0))
}

@Test("scoreboard maps detections before testing whether their centers hit keys")
func scoreboardMapsBeforeCenterScoring() {
    let panel = rectangularQuad(minX: 0.25, minY: 0.2, maxX: 0.75, maxY: 0.6)
    let expected = map(label: "Start", bounds: PanelRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2))
    let sample = labelledSample(panel: panel, expected: expected)
    let photoSpaceDetection = map(
        label: "Start",
        bounds: PanelRect(x: 0.60, y: 0.48, width: 0.10, height: 0.08)
    )

    let mapped = TestSet.scoreboardResult(
        photo: sample.id,
        detected: photoSpaceDetection,
        detectedPanel: .fullFrame,
        sample: sample,
        seconds: 0
    )
    let unmapped = TestSet.scoreboardResult(
        photo: sample.id,
        detected: photoSpaceDetection,
        detectedPanel: panel,
        sample: sample,
        seconds: 0
    )

    #expect(mapped.recall == 1)
    #expect(unmapped.recall == 0)
}

@Test("scoreboard reports Start matched onto the 9 key as wrong")
func scoreboardStartOnNineIsWrong() {
    let bounds = PanelRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
    let sample = labelledSample(panel: .fullFrame, expected: map(label: "9", bounds: bounds))
    let detected = map(label: "Start", bounds: bounds)

    let result = TestSet.scoreboardResult(
        photo: sample.id,
        detected: detected,
        detectedPanel: .fullFrame,
        sample: sample,
        seconds: 0
    )

    #expect(result.start == .wrongKey("9"))
}

@Test("scoreboard accepts Start Pause for the Start/Pause answer key")
func scoreboardLabelIgnoresPunctuation() {
    let bounds = PanelRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)
    let sample = labelledSample(panel: .fullFrame, expected: map(label: "Start/Pause", bounds: bounds))
    let detected = map(label: "Start Pause", bounds: bounds)

    let result = TestSet.scoreboardResult(
        photo: sample.id,
        detected: detected,
        detectedPanel: .fullFrame,
        sample: sample,
        seconds: 0
    )

    #expect(result.correctLabels == 1)
}

@Test("scoreboard empty detections have zero recall and unavailable precision")
func scoreboardEmptyMapDoesNotScoreOne() {
    let sample = labelledSample(
        panel: .fullFrame,
        expected: map(label: "Start", bounds: PanelRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
    )

    let result = TestSet.scoreboardResult(
        photo: sample.id,
        detected: SurfaceMap(buttons: [], confidence: 0),
        detectedPanel: .fullFrame,
        sample: sample,
        seconds: 0
    )
    let totals = ScoreboardTotals([result])

    #expect(result.recall == 0)
    #expect(result.precision == nil)
    #expect(totals.recall == 0)
    #expect(totals.precision == nil)
}

private func map(label: String?, bounds: PanelRect) -> SurfaceMap {
    SurfaceMap(
        buttons: [
            SurfaceMap.Button(label: label, bounds: bounds, confidence: 1)
        ],
        confidence: 1
    )
}

private func labelledSample(panel: PanelQuad, expected: SurfaceMap) -> LabelledSample {
    LabelledSample(
        id: "fixture.jpg",
        appliance: "fixture",
        lighting: "test",
        panel: panel,
        expected: expected
    )
}

private func rectangularQuad(
    minX: Double,
    minY: Double,
    maxX: Double,
    maxY: Double
) -> PanelQuad {
    PanelQuad(
        topLeft: ImagePoint(x: minX, y: minY),
        topRight: ImagePoint(x: maxX, y: minY),
        bottomRight: ImagePoint(x: maxX, y: maxY),
        bottomLeft: ImagePoint(x: minX, y: maxY)
    )
}

private func expectEqual(_ actual: PanelRect, _ expected: PanelRect) {
    #expect(abs(actual.minX - expected.minX) < 1e-9)
    #expect(abs(actual.minY - expected.minY) < 1e-9)
    #expect(abs(actual.width - expected.width) < 1e-9)
    #expect(abs(actual.height - expected.height) < 1e-9)
}
