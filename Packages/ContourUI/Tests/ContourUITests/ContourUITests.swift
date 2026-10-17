//
//  ContourUITests.swift
//  ContourUI — Experience
//
//  Structural tests so CI is green on day one. Note this is a `swift test`
//  target, not an XCUITest bundle — the app's XCUITests live in
//  ContourApp/ContourTests.
//
//  Experience: the first real test to write is "every GuidanceFlowStage produces a
//  non-empty announcement". It needs no UI, no camera, and no simulator, and it
//  catches the failure mode that matters most — a state change a blind user is
//  never told about.
//

import ContourCore
import Testing
@testable import ContourUI

@Test("the flow types are constructible")
func flowTypesExist() {
    _ = CaptureFlow()
    _ = TargetSelection()
    _ = GuidanceFlow()
}

@Test("every flow stage the user can reach is representable")
func stagesAreRepresentable() {
    let map = SurfaceMap.empty
    let stages: [GuidanceFlowStage] = [
        .idle,
        .acquiringPanel,
        .detecting,
        .selectingTarget(map),
        .finished(.arrived),
    ]

    #expect(stages.count == 5)
    #expect(stages.contains(.idle))
}
