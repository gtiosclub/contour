//
//  SurfaceUnderstandingTests.swift
//  SurfaceUnderstanding — Surface Understanding
//
//  Structural tests so CI is green on day one. They assert that the package
//  builds and still satisfies the contract — nothing about detection, because
//  there is no detection yet.
//
//  Surface Understanding: your real tests score `LiveSurfaceUnderstanding` against
//  `TestSet.samples`. Write the first one the day you label the first photo.
//

import ContourCore
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

@Test("the test set starts empty and is waiting for Week 2 labels")
func testSetIsEmptyForNow() {
    #expect(TestSet.samples.isEmpty, "add a LabelledSample per hand-labelled photo")
}

@Test("a full-frame quad covers the unit square")
func fullFrameQuad() {
    #expect(PanelQuad.fullFrame.topLeft == PanelPoint(x: 0, y: 0))
    #expect(PanelQuad.fullFrame.bottomRight == PanelPoint(x: 1, y: 1))
}
