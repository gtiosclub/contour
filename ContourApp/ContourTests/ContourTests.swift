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

    @Test("stopping guidance leaves the feedback engine with nothing to play")
    func stoppingSilencesFeedback() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: MockTrackingSource(steps: 1_000, interval: .milliseconds(10)),
            feedback: engine,
            liveComponents: []
        )

        let session = Task { await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton) }
        try await Task.sleep(for: .milliseconds(100))
        session.cancel()
        await session.value

        let last = try #require(await engine.received.last)
        #expect(last.vector == nil && last.outcome == nil, "last state was \(last)")
    }

    @Test("Rescanning stops guidance for the previous panel")
    func rescanStopsOldGuidance() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let source = ControlledFrames()
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: source, feedback: engine, liveComponents: [])
        let session = Task { await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton) }
        await source.waitForSubscription()
        _ = try await pipeline.detectPanel(in: PanelPhoto(data: Data(),
            pixelSize: PixelSize(width: 100, height: 100), timestamp: Date()))
        source.send(TrackingFrame(timestamp: Date(), fingertip: PanelPoint(x: 0.1, y: 0.1),
            panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
        source.finish()
        await session.value
        #expect(await engine.received.allSatisfy { $0.vector == nil })
    }

    @Test("A delayed scan cannot replace a newer manual reference")
    func delayedScanCannotReplaceManualReference() async throws {
        let surface = DeferredSurface()
        let pipeline = ContourPipeline(surfaceUnderstanding: surface,
            tracking: MockTrackingSource(), feedback: PrintingFeedbackEngine(isPrinting: false),
            liveComponents: [])
        let oldPhoto = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
        let scan = Task { try await pipeline.detectPanel(in: oldPhoto) }
        await surface.waitForDetection()
        let newPhoto = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
        let replacement = try PanelReference(photo: newPhoto, detection: PanelDetection(
            referencePhotoID: newPhoto.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
        await pipeline.replaceReference(with: replacement)
        await surface.finish()
        do {
            _ = try await scan.value
            Issue.record("Superseded scan should be cancelled")
        } catch is CancellationError {
            // Expected: the manual reference owns the session now.
        }
        #expect(pipeline.panelReference?.photo.id == newPhoto.id)
    }

    @Test("A full-frame fallback map cannot start live guidance")
    func fullFrameCannotGuideLive() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: MockTrackingSource(steps: 1, interval: .milliseconds(1)),
            feedback: engine, liveComponents: [.tracking])
        _ = try await pipeline.detectPanel(in: PanelPhoto(data: Data(),
            pixelSize: PixelSize(width: 100, height: 100), timestamp: Date()))
        #expect(!pipeline.canGuide)
        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)
        #expect(await engine.received.isEmpty)
    }

    @Test("a brief tracking loss isn't announced, a longer one is announced once")
    func lossIsDebounced() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let start = Date(timeIntervalSince1970: 1_000)
        let at = { (seconds: Double) in start.addingTimeInterval(seconds) }
        let good = { (seconds: Double) in
            TrackingFrame(timestamp: at(seconds), fingertip: PanelPoint(x: 0.1, y: 0.1),
                          panel: PanelPose(column0: SIMD4(1, 0, 0, 0), column1: SIMD4(0, 1, 0, 0),
                                           column2: SIMD4(0, 0, 1, 0), column3: SIMD4(0, 0, 0, 1),
                                           confidence: 1),
                          trackingQuality: .good)
        }
        // Lost for 0.1 s (a blur), back, then lost for 0.5 s.
        let frames = [good(0), .lost(at: at(0.05)), .lost(at: at(0.15)), good(0.2),
                      .lost(at: at(0.3)), .lost(at: at(0.5)), .lost(at: at(0.7)), .lost(at: at(0.8))]
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedFrames(script: frames),
            feedback: engine,
            liveComponents: []
        )

        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)

        #expect(await engine.outcomes == [.lostTracking])
    }
}

/// A tracking source that plays back fixed frames and finishes.
private struct ScriptedFrames: TrackingSource {
    let script: [TrackingFrame]
    func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { continuation in
            script.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}


private final class ControlledFrames: TrackingSource, @unchecked Sendable {
    private let pair = AsyncStream<TrackingFrame>.makeStream()
    private let lock = NSLock()
    private var subscribed = false
    private var waiter: CheckedContinuation<Void, Never>?
    func frames() -> AsyncStream<TrackingFrame> {
        lock.withLock {
            subscribed = true
            waiter?.resume()
            waiter = nil
        }
        return pair.stream
    }
    func waitForSubscription() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if subscribed { continuation.resume() } else { waiter = continuation }
            }
        }
    }
    func send(_ frame: TrackingFrame) { pair.continuation.yield(frame) }
    func finish() { pair.continuation.finish() }
}

private actor DeferredSurface: ContourCore.SurfaceUnderstanding {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Void, Never>?
    func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        started = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { result = $0 }
        return PanelDetection(referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave)
    }
    func waitForDetection() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { result?.resume(); result = nil }
}
