//
//  LaneTests.swift
//  SurfaceUnderstandingTests
//
//  One test per lane. Each one is `.disabled` because the stub it calls is a
//  `fatalError`, and a fatalError takes the whole test process down with it.
//
//  When your lane works: delete the `.disabled(...)` line on YOUR test, run
//  `swift test`, and open the PR when it's green. That's the definition of done.
//
//  The fixture tests at the top are always on. They prove the synthetic photo
//  decodes and the helpers work, so if something's broken you know it's your
//  lane and not the harness.
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import SurfaceUnderstanding

// MARK: - Fixtures (always on)

@Test("the synthetic panel photo decodes to the size it claims")
func syntheticPhotoDecodes() throws {
    let photo = try SyntheticPanel.photo()
    let image = try photo.cgImage()
    #expect(image.width == SyntheticPanel.size.width)
    #expect(image.height == SyntheticPanel.size.height)
}

@Test("cgImage() uprights a rotated photo")
func rotatedPhotoIsUprighted() throws {
    let photo = try SyntheticPanel.photo(orientation: .right)
    let image = try photo.cgImage()
    // Rotating a 900×600 by a right angle gives 600×900.
    #expect(image.width == SyntheticPanel.size.height)
    #expect(image.height == SyntheticPanel.size.width)
}

@Test("garbage bytes throw undecodableImage, not a crash")
func garbageThrows() {
    let junk = PanelPhoto(
        data: Data([0x00, 0x01, 0x02]),
        pixelSize: PixelSize(width: 1, height: 1),
        timestamp: .now
    )
    #expect(throws: SurfaceUnderstandingError.undecodableImage) {
        _ = try junk.cgImage()
    }
}

// MARK: - Panel Detector — Aarav

@Test("Panel Detector: finds a full-frame panel and rectifies its centre",
      .disabled("Aarav — delete this line when PanelDetector works"))
func panelDetectorFindsThePanel() async throws {
    let photo = try SyntheticPanel.photo()
    let detector = PanelDetector()

    let (quad, confidence) = try await detector.detectPanel(in: photo)

    // The synthetic panel fills the frame, so the quad should be near the corners.
    #expect(quad.topLeft.x < 0.05 && quad.topLeft.y < 0.05)
    #expect(quad.bottomRight.x > 0.95 && quad.bottomRight.y > 0.95)
    #expect(confidence > 0.5)

    // Rectifying the image centre through a full-frame quad gives the panel centre.
    let centre = detector.rectify(ImagePoint(x: 0.5, y: 0.5), within: .fullFrame)
    #expect(abs(centre.x - 0.5) < 0.01)
    #expect(abs(centre.y - 0.5) < 0.01)
}

// MARK: - Button Detector — Sanvi

@Test("Button Detector: finds six buttons roughly where the mock says they are",
      .disabled("Sanvi — delete this line when ButtonDetector works"))
func buttonDetectorFindsSixButtons() async throws {
    let photo = try SyntheticPanel.photo()
    let found = try await ButtonDetector().detectButtons(in: photo, panel: .fullFrame)

    #expect(found.count == SyntheticPanel.expected.buttons.count)

    // Every expected button should have a detected box overlapping its centre.
    for expected in SyntheticPanel.expected.buttons {
        let hit = found.contains { $0.bounds.contains(expected.bounds.center) }
        #expect(hit, "no detected box covers \(expected.label ?? "?")")
    }
}

// MARK: - Labels — Srinivas

@Test("Labels: reads the label on each button region",
      .disabled("Srinivas — delete this line when LabelReader works"))
func labelReaderReadsStart() async throws {
    let photo = try SyntheticPanel.photo()
    let regions = SyntheticPanel.expected.buttons.map(\.bounds)

    let labels = try await LabelReader().readLabels(in: photo, panel: .fullFrame, regions: regions)

    #expect(labels.count == regions.count)
    let read = labels.compactMap { $0?.lowercased() }
    #expect(read.contains("start"))
    #expect(read.contains("popcorn"))
}

// MARK: - Target Matching — Asav

@Test("Target Matching: synonyms hit, missing buttons return nil",
      .disabled("Asav — delete this line when TargetMatcher works"))
func targetMatcherResolvesRequests() throws {
    let map = MockSurfaceMaps.microwave
    let matcher = TargetMatcher()
    let start = try #require(map.button(labelled: "Start"))

    for request in ["Start", "start", "GO", "begin", "  start! "] {
        let match = matcher.match(request, in: map)
        #expect(match?.button.id == start.id, "\"\(request)\" should resolve to Start")
    }

    // Popcorn exists on the mock; remove it and the request must come back nil.
    var noPopcorn = map
    noPopcorn.buttons.removeAll { $0.label == "Popcorn" }
    #expect(matcher.match("popcorn", in: noPopcorn) == nil)

    // Fuzzy: a space in the wrong place still finds it on the full map.
    #expect(matcher.match("pop corn", in: map)?.button.label == "Popcorn")
}

// MARK: - Eval & Test Set — Vrishin

@Test("Eval: a perfect detection scores 1.0 on everything",
      .disabled("Vrishin — delete this line when TestSet.score works"))
func perfectDetectionScoresOne() {
    let map = MockSurfaceMaps.microwave
    let score = TestSet.score(detected: map, against: map)
    #expect(score.recall == 1)
    #expect(score.precision == 1)
    #expect(score.labelAccuracy == 1)
}

@Test("Eval: dropping one button costs recall but not precision",
      .disabled("Vrishin — delete this line when TestSet.score works"))
func missingButtonCostsRecall() {
    let expected = MockSurfaceMaps.microwave
    var detected = expected
    detected.buttons.removeLast()

    let score = TestSet.score(detected: detected, against: expected)
    #expect(abs(score.recall - 5.0 / 6.0) < 0.001)
    #expect(score.precision == 1)
}
