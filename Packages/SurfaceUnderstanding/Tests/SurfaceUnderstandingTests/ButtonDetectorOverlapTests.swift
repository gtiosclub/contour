//
//  ButtonDetectorOverlapTests.swift
//  SurfaceUnderstanding
//
//  Created by Sanvi Adusumilli on 10/13/26.
//

import ContourCore
import Foundation
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

private func boxesOverlap(_ first: PanelRect, _ second: PanelRect) -> Bool {
    first.origin.x < second.origin.x + second.width
        && second.origin.x < first.origin.x + first.width
        && first.origin.y < second.origin.y + second.height
        && second.origin.y < first.origin.y + first.height
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
    #expect(found.contains { $0.bounds.contains(outer.center) })
    #expect(found.contains { $0.bounds.contains(overlapping.center) })

    for i in found.indices {
        for j in found.indices where j > i {
            #expect(!boxesOverlap(found[i].bounds, found[j].bounds))
        }
    }
}

@Test("three overlapping boxes survive without overlapping")
func threeOverlappingBoxesKeepValidKeys() {
    let first = PanelRect(x: 0.10, y: 0.10, width: 0.20, height: 0.10)
    let second = PanelRect(x: 0.25, y: 0.10, width: 0.20, height: 0.10)
    let third = PanelRect(x: 0.40, y: 0.10, width: 0.20, height: 0.10)

    let results: [(bounds: PanelRect, confidence: Double)] = [
        (first, 1.0),
        (second, 1.0),
        (third, 1.0)
    ]

    let found = removeOverlappingBoxes(results)

    #expect(found.count == 3)
    #expect(found.contains { $0.bounds.contains(first.center) })
    #expect(found.contains { $0.bounds.contains(second.center) })
    #expect(found.contains { $0.bounds.contains(third.center) })

    for i in found.indices {
        for j in found.indices where j > i {
            #expect(!boxesOverlap(found[i].bounds, found[j].bounds))
        }
    }
}

@Test("boxes just outside the panel edge finish trimming")
func boxesJustOutsidePanelEdgeFinishTrimming() {
    let first = PanelRect(
        x: 0.3041384498417196,
        y: 0.004629823014080703,
        width: 0.16787870658274534,
        height: 0.054682117754759965
    )
    let second = PanelRect(
        x: 0.412155085289509,
        y: -0.003197852193613776,
        width: 0.1614892474552609,
        height: 0.059878604219697346
    )
    let results: [(bounds: PanelRect, confidence: Double)] = [
        (first, 1.0),
        (second, 1.0)
    ]
    let finished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
        _ = removeOverlappingBoxes(results)
        finished.signal()
    }

    #expect(finished.wait(timeout: .now() + 3) == .success)
}
