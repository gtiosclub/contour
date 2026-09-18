//
//  ContourTests.swift
//  ContourTests
//
//  Tests for the wiring, not for anyone's feature. Feature tests belong in the
//  owning package, where they run under `swift test` in seconds without a
//  simulator.
//
//  These run under `xcodebuild test`, which CI does not do on every push — see
//  .github/workflows/ci.yml. Keep them few and keep them fast.
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Pipeline wiring")
struct PipelineWiringTests {

    @Test("the mock pipeline reports every component as mocked")
    func mockPipelineIsFullyMocked() {
        let pipeline = ContourPipeline.mock()
        #expect(pipeline.liveComponents.isEmpty)
    }

    @Test("the mock pipeline detects the canned microwave end to end")
    func detectionRunsThroughTheWiring() async throws {
        let pipeline = ContourPipeline.mock()
        let photo = PanelPhoto(
            data: Data(),
            pixelSize: PixelSize(width: 4032, height: 3024),
            timestamp: MockTrackingSource.fixedEpoch
        )

        let map = try await pipeline.detectPanel(in: photo)

        #expect(pipeline.panelReference?.photo == photo)
        #expect(pipeline.panelReference?.detection.map == map)
        #expect(map.buttons.count == 6)
        #expect(map.button(labelled: "Start") != nil)
    }

    @Test("guidance runs frames from the tracking source into the feedback engine")
    func guidanceRunsEndToEnd() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: MockTrackingSource(steps: 3, interval: .milliseconds(1)),
            feedback: engine,
            liveComponents: []
        )

        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)

        let received = await engine.received
        #expect(received.count == 4)
        #expect(await engine.outcomes.last == .arrived)
    }
}
