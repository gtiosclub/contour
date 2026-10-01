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
