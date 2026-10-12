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

// Prints what match() returns for the PR's before/after table. Don't commit this file.
//
//   REPORT=1 swift test --filter matcherReport
//
// Skipped unless REPORT is set.

@Test("matcher report", .enabled(if: ProcessInfo.processInfo.environment["REPORT"] != nil))
func matcherReport() {
    let requests = ["start", "stop", "pause", "timer", "time", "clock", "add 30 seconds", "power"]
    // The 18 microwave lists: everything in RealPanelLabels except the 2 ovens and the hand-labelled panels.
    let photos = RealPanelLabels.lists.keys
        .filter { !$0.hasPrefix("hand-labelled") && !$0.lowercased().contains("oven") }
        .sorted()

    var table = "| Photo | " + requests.joined(separator: " | ") + " |\n"
    table += "|---|" + String(repeating: "---|", count: requests.count) + "\n"
    for photo in photos {
        let labels = RealPanelLabels.lists[photo]!
        let map = SurfaceMap(buttons: labels.enumerated().map { i, label in
            SurfaceMap.Button(label: label, bounds: PanelRect(x: 0, y: Double(i) / Double(labels.count), width: 1, height: 0.01), confidence: 1)
        }, confidence: 1)
        let cells = requests.map { request -> String in
            guard let match = TargetMatcher().match(request, in: map) else { return "nil" }
            return "\(match.button.label ?? "?") (\(String(format: "%.1f", match.confidence)))"
        }
        table += "| \(photo) | " + cells.joined(separator: " | ") + " |\n"
    }
    print("\n\(photos.count) microwave lists\n\n\(table)")
}

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
