//
//  ButtonDetectorTests.swift
//  SurfaceUnderstandingTests — Surface / Button Detector
//
//  The case the lane test can't see: a rectangle around a group of keys.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

@Test("Button Detector: keys on a raised plate each get their own box")
func buttonDetectorKeepsKeysOnAPlate() async throws {
    let (photo, keys) = try SyntheticPanel.groupedKeysPhoto()

    let found = try await ButtonDetector().detectButtons(in: photo, panel: .fullFrame)

    // One box per key, and no box covering several keys. Keeping the larger of
    // two overlapping boxes returned the plate instead of the four keys on it.
    #expect(found.count == keys.count)
    for key in keys {
        #expect(found.contains { $0.bounds.contains(key.center) }, "no box covers the key at \(key.center)")
    }
    for box in found {
        let covered = keys.filter { box.bounds.contains($0.center) }.count
        #expect(covered <= 1, "\(box.bounds) covers \(covered) keys")
    }
}

@Test("Button Detector: ignores rectangles outside the panel")
func buttonDetectorIgnoresClutterOutsidePanel() async throws {
    let (photo, quad) = try SyntheticPanel.insetPhotoWithClutter()

    let found = try await ButtonDetector().detectButtons(
        in: photo,
        panel: quad
    )

    #expect(found.count == SyntheticPanel.expected.buttons.count)
    
    for expected in SyntheticPanel.expected.buttons {
        #expect(
            found.contains { $0.bounds.contains(expected.bounds.center) },
            "no detected box covers \(expected.label ?? "?")"
        )
    }
}

@Test("Button Detector: keeps key when label rectangles are nested inside it")
func buttonDetectorKeepsKeyWithDuplicateLabel() async throws {
    let (photo, key) = try SyntheticPanel.duplicateLabelPhoto()

    let found = try await ButtonDetector().detectButtons(
        in: photo,
        panel: .fullFrame
    )

    #expect(found.count == 1)

    #expect(abs(found[0].bounds.origin.x - key.origin.x) < 0.01)
    #expect(abs(found[0].bounds.origin.y - key.origin.y) < 0.01)
    #expect(abs(found[0].bounds.width - key.width) < 0.01)
    #expect(abs(found[0].bounds.height - key.height) < 0.01)
}

@Test("Button Detector: ignores digits when quad covers only the display")
func buttonDetectorRejectsDisplayOnlyQuad() async throws {
    let (photo, displayQuad) = try SyntheticPanel.displayQuadPhoto()

    let displayResults = try await ButtonDetector().detectButtons(
        in: photo,
        panel: displayQuad
    )

    let fullFrameResults = try await ButtonDetector().detectButtons(
        in: photo,
        panel: .fullFrame
    )

    #expect(displayResults.isEmpty)
    #expect(fullFrameResults.count >= 6)
}
