//
//  SurfaceUnderstandingTests.swift
//  SurfaceUnderstanding — Surface Understanding
//
//  Structural tests so CI is green on day one. They assert that the package
//  builds and still satisfies the contract — nothing about detection, because
//  there is no detection yet.
//
//  Surface Understanding: your real tests score `LiveSurfaceUnderstanding`
//  against `TestSet.samples`. Write the first one the day you label the first
//  photo.
//
//  This test target may import ContourMocks; the source target may not. Build
//  fixtures out of the shared fakes rather than hand-rolling a SurfaceMap here —
//  the canned microwave is what every other team is testing against too.
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import SurfaceUnderstanding

@Test("LiveSurfaceUnderstanding still satisfies the ContourCore contract")
func conformsToContract() {
    let subject: any ContourCore.SurfaceUnderstanding = LiveSurfaceUnderstanding()
    #expect(subject is LiveSurfaceUnderstanding)
}

@Test("the detection stages are constructible")
func stagesExist() {
    _ = PanelDetector()
    _ = ButtonDetector()
    _ = LabelReader()
}

@Test("the target matcher is constructible")
func targetMatcherExists() {
    _ = TargetMatcher()
}

@Test("a TargetMatch carries the button and a separate match confidence")
func targetMatchKeepsBothConfidences() throws {
    // Defrost is the deliberately scuffed detection in the canned panel.
    let button = try #require(MockSurfaceMaps.microwave.button(labelled: "Defrost"))

    let match = TargetMatch(button: button, confidence: 0.92)

    // Detector confidence and match confidence are independent on purpose: the
    // matcher can be sure what the user meant while the detector is unsure the
    // button is really there.
    #expect(match.confidence == 0.92)
    #expect(match.button.confidence == 0.61)
    #expect(match.confidence != match.button.confidence)
}

@Test("the canned panel gives the matcher labelled buttons to match against")
func mockPanelIsMatchable() {
    let labelled = MockSurfaceMaps.microwave.buttons.filter { $0.label != nil }
    #expect(labelled.count == MockSurfaceMaps.microwave.buttons.count,
            "every button in the canned panel should be labelled")
}

@Test("the checked-in answer key loads ten labelled photos")
func testSetLoadsAnswerKeys() {
    #expect(TestSet.samples.count == 10)
    #expect(TestSet.samples.first?.id == "microwave-01.jpg")
    #expect(TestSet.samples.last?.id == "microwave-10.jpg")
    #expect(TestSet.samples.allSatisfy { !$0.expected.buttons.isEmpty })
}

@Test("button scoring uses one-to-one matches at 50 percent IoU")
func testSetScoresButtonsOneToOne() {
    let bounds = PanelRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
    let expected = SurfaceMap(
        buttons: [SurfaceMap.Button(label: "Start", bounds: bounds, confidence: 1)],
        confidence: 1
    )
    let duplicate = SurfaceMap.Button(label: "start", bounds: bounds, confidence: 0.8)
    let detected = SurfaceMap(buttons: [duplicate, duplicate], confidence: 0.9)

    let score = TestSet.score(detected: detected, against: expected)

    #expect(score.recall == 1)
    #expect(score.precision == 0.5)
    #expect(score.labelAccuracy == 1)
}

@Test("MockSurfaceUnderstanding prints a test-set score")
func mockSurfaceUnderstandingPrintsScore() async throws {
    let photo = PanelPhoto(
        data: Data(),
        pixelSize: PixelSize(width: 1, height: 1),
        timestamp: .distantPast
    )
    let detection = try await MockSurfaceUnderstanding().detectPanel(from: photo)
    let baseline = TestSet.score(
        detected: detection.map,
        against: MockSurfaceMaps.microwave
    )
    let baselineOverall = (baseline.precision + baseline.recall + baseline.labelAccuracy) / 3
    let scores = TestSet.samples.map {
        TestSet.score(detected: detection.map, against: $0.expected)
    }
    let count = Double(scores.count)
    let precision = scores.reduce(0) { $0 + $1.precision } / count
    let recall = scores.reduce(0) { $0 + $1.recall } / count
    let labels = scores.reduce(0) { $0 + $1.labelAccuracy } / count
    let overall = (precision + recall + labels) / 3

    print(String(
        format: "MockSurfaceUnderstanding baseline: %.3f; photo corpus: %.3f (precision %.3f, recall %.3f, labels %.3f)",
        baselineOverall,
        overall,
        precision,
        recall,
        labels
    ))

    #expect(baselineOverall == 1)
    #expect(overall.isFinite)
    #expect((0...1).contains(overall))
}

@Test("a full-frame quad covers the unit square")
func fullFrameQuad() {
    #expect(PanelQuad.fullFrame.topLeft == ImagePoint(x: 0, y: 0))
    #expect(PanelQuad.fullFrame.bottomRight == ImagePoint(x: 1, y: 1))
}
