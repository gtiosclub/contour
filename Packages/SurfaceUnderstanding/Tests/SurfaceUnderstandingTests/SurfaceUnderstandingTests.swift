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
import Testing
import Foundation
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

@Test("a full-frame quad covers the unit square")
func fullFrameQuad() {
    #expect(PanelQuad.fullFrame.topLeft == ImagePoint(x: 0, y: 0))
    #expect(PanelQuad.fullFrame.bottomRight == ImagePoint(x: 1, y: 1))
}

@Test("word matches and fallbacks stay below 0.9", arguments: [
    // Word matches (pass 2): the request is only part of the label
    ("normal_microwave.jpg", "start",          "Start Pause"),
    ("Neat2.jpeg",           "power",          "Power Level"),
    ("Neat2.jpeg",           "add 30 seconds", "30 Add Sec"),
    ("microwave1_neat.heif", "timer",          "Timer Set/Off"),
    // Fallbacks: the asked-for key isn't on the panel
    ("normal_microwave.jpg", "stop",           "Cancel Off"),
    ("Neat2.jpeg",           "stop",           "Cancel"),
    ("microwave2-glare.jpg", "pause",          "STOP"),
])
func partialMatchesStayBelowSynonymConfidence(panel: String, say: String, label: String) throws {
    let result = try #require(TargetMatcher().match(say, in: RealPanelLabels.map(panel)))
    #expect(result.button.label == label)
    #expect(result.confidence < 0.9)
}
