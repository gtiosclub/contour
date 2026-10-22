//
//  ButtonDetectorOverlapTests.swift
//  SurfaceUnderstanding
//
//  Created by Sanvi Adusumilli on 10/13/26.
//

import ContourCore
import Testing
@testable import SurfaceUnderstanding

@Test("duplicate label boxes are removed while the key survives")
func duplicateLabelBoxesKeepKey() {
    let key = PanelRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20)
    let label1 = PanelRect(x: 0.13, y: 0.15, width: 0.14, height: 0.08)
    let label2 = PanelRect(x: 0.135, y: 0.155, width: 0.13, height: 0.07)

    let results: [(bounds: PanelRect, confidence: Double)] = [
        (key, 1.0),
        (label1, 1.0),
        (label2, 1.0)
    ]

    let found = removeOverlappingBoxes(results)

    #expect(found.count == 1)
    #expect(found.first?.bounds == key)
}

@Test("a plate around four keys is removed while the keys survive")
func plateAroundFourKeysKeepsKeys() {
    let plate = PanelRect(x: 0.08, y: 0.15, width: 0.40, height: 0.44)

    let keys = [
        PanelRect(x: 0.10, y: 0.18, width: 0.17, height: 0.175),
        PanelRect(x: 0.29, y: 0.18, width: 0.17, height: 0.175),
        PanelRect(x: 0.10, y: 0.385, width: 0.17, height: 0.175),
        PanelRect(x: 0.29, y: 0.385, width: 0.17, height: 0.175)
    ]

    let results: [(bounds: PanelRect, confidence: Double)] =
        [(plate, 1.0)] + keys.map { ($0, 1.0) }

    let found = removeOverlappingBoxes(results)

    #expect(found.count == 4)
    for key in keys {
        #expect(found.contains { $0.bounds == key })
    }
}

@Test("half-overlapping boxes survive when the smaller center is outside")
func halfOverlappingBoxesKeepValidKey() {
    let outer = PanelRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20)
    let overlapping = PanelRect(x: 0.25, y: 0.15, width: 0.20, height: 0.10)

    let results: [(bounds: PanelRect, confidence: Double)] = [
        (outer, 1.0),
        (overlapping, 1.0)
    ]

    let found = removeOverlappingBoxes(results)

    #expect(found.count == 2)
    #expect(found.contains { $0.bounds == outer })
    #expect(found.contains { $0.bounds == overlapping })
}
