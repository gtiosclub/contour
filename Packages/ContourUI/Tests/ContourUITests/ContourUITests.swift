//
//  ContourUITests.swift
//  ContourUI — Experience
//
//  The screens' pure parts: panel-to-photo mapping, what the guide screen
//  shows for each guidance state, and what each outcome says. Note this is a
//  `swift test` target, not an XCUITest bundle — the app's tests live in
//  ContourApp/ContourTests.
//

import ContourCore
import ContourMocks
import Foundation
import SwiftUI
import Testing
@testable import ContourUI

@Test("the flow types are constructible")
func flowTypesExist() {
    _ = CaptureFlow()
    _ = TargetSelection()
    _ = GuidanceFlow()
}

@MainActor
@Test("every screen takes plain data and closures, no camera and no pixels")
func screensTakePlainData() {
    let map = MockSurfaceMaps.microwave
    let start = MockSurfaceMaps.microwaveStartButton
    _ = AcquireScreen(message: "Hint", onScan: {}) { Color.black }
    _ = DetectingScreen(photo: nil, sample: map, onCancel: {}) { Color.black }
    _ = SelectScreen(map: map, onChoose: { _ in }, onSay: {}, onRescan: {})
    _ = GuideScreen(target: start, guidance: nil, onStop: {}) { Color.black }
    for outcome in OutcomeSignal.allCases {
        _ = OutcomeScreen(outcome: outcome, onGuideAgain: nil, onChooseAnother: nil, onScanNew: {})
    }
    _ = ViewfinderPlaceholder(sample: map, message: "Camera unavailable in Simulator")
}

@Suite("Panel space to photo space")
struct PanelImageMappingTests {

    @Test("a full-frame quad is the identity")
    func identity() throws {
        let mapping = try #require(PanelImageMapping(quad: .fullFrame))
        let point = try #require(mapping.imagePoint(for: PanelPoint(x: 0.25, y: 0.75)))
        #expect(abs(point.x - 0.25) < 1e-9 && abs(point.y - 0.75) < 1e-9)
    }

    @Test("corners land on the quad's corners, y down")
    func corners() throws {
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.2, y: 0.1), topRight: ImagePoint(x: 0.9, y: 0.2),
                             bottomRight: ImagePoint(x: 0.8, y: 0.9), bottomLeft: ImagePoint(x: 0.1, y: 0.7))
        let mapping = try #require(PanelImageMapping(quad: quad))
        let expected = [(PanelPoint.origin, quad.topLeft), (PanelPoint(x: 1, y: 0), quad.topRight),
                        (PanelPoint(x: 1, y: 1), quad.bottomRight), (PanelPoint(x: 0, y: 1), quad.bottomLeft)]
        for (panel, image) in expected {
            let mapped = try #require(mapping.imagePoint(for: panel))
            #expect(abs(mapped.x - image.x) < 1e-9 && abs(mapped.y - image.y) < 1e-9, "\(panel)")
        }
    }

    @Test("a centred inset quad maps the panel centre to its centre")
    func inset() throws {
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.2), topRight: ImagePoint(x: 0.9, y: 0.2),
                             bottomRight: ImagePoint(x: 0.9, y: 0.8), bottomLeft: ImagePoint(x: 0.1, y: 0.8))
        let mapping = try #require(PanelImageMapping(quad: quad))
        let centre = try #require(mapping.imagePoint(for: .center))
        #expect(abs(centre.x - 0.5) < 1e-9 && abs(centre.y - 0.5) < 1e-9)
        #expect(mapping.corners(of: MockSurfaceMaps.microwaveStartButton.bounds)?.count == 4)
    }

    @Test("a degenerate quad has no mapping")
    func degenerate() {
        let point = ImagePoint(x: 0.5, y: 0.5)
        #expect(PanelImageMapping(quad: PanelQuad(topLeft: point, topRight: point,
                                                  bottomRight: point, bottomLeft: point)) == nil)
    }
}

@Suite("What the guide screen shows")
struct GuideStatusTests {

    private func moving(_ dx: Double, _ dy: Double, distance: Double) -> GuidanceState {
        GuidanceState(timestamp: MockTrackingSource.fixedEpoch,
                      vector: GuidanceVector(direction: PanelVector(dx: dx, dy: dy), normalizedDistance: distance))
    }

    @Test("before the first state, it is starting")
    func starting() {
        #expect(GuideStatus(nil).phase == .starting)
    }

    @Test("moving down points the arrow down the screen and fills the ring")
    func movingDown() {
        let status = GuideStatus(moving(0, 1, distance: 0.25))
        #expect(status.phase == .moving)
        #expect(abs((status.angle ?? 0) - .pi / 2) < 1e-9)   // clockwise from right: down
        #expect(status.fill == 0.75)
        #expect(status.spoken == "Close. Move down.")
    }

    @Test("each outcome has its own look")
    func outcomes() {
        let at = MockTrackingSource.fixedEpoch
        #expect(GuideStatus(.outcome(.arrived, at: at)).phase == .onTarget)
        #expect(GuideStatus(.outcome(.lostTracking, at: at)).phase == .lost)
        #expect(GuideStatus(.outcome(.lowConfidence, at: at)).phase == .unclear)
        #expect(GuideStatus(GuidanceState(timestamp: at, vector: nil)).phase == .noFinger)
        #expect(GuideStatus(GuidanceState(timestamp: at, vector: .onTarget)).phase == .onTarget)
    }

    @Test("the mock walk toward Start reads as a steady approach")
    func mockWalk() {
        let source = MockTrackingSource()
        let fills = (0...source.steps).map { step in
            GuideStatus(MockGuidance.state(for: source.frame(atStep: step),
                                           target: MockSurfaceMaps.microwaveStartButton)).fill
        }
        #expect(fills == fills.sorted())
        #expect(fills.last == 1)
    }
}

@Suite("What each outcome says")
struct OutcomeContentTests {

    @Test("every outcome has its own title, message and symbol")
    func distinct() {
        let contents = OutcomeSignal.allCases.map { OutcomeContent(outcome: $0) }
        #expect(Set(contents.map(\.title)).count == 4)
        #expect(Set(contents.map(\.message)).count == 4)
        #expect(Set(contents.map(\.symbol)).count == 4)
    }

    @Test("arriving names the target")
    func arrivedNamesTarget() {
        #expect(OutcomeContent(outcome: .arrived, targetName: "Start").title == "You're on Start")
    }

    @Test("a detail replaces the default message")
    func detail() {
        let content = OutcomeContent(outcome: .notFound, detail: "No button called \u{201C}pizza\u{201D}.")
        #expect(content.message == "No button called \u{201C}pizza\u{201D}.")
    }
}
