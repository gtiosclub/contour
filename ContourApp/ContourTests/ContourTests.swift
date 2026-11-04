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
import ContourFeedback
import Foundation
import Testing
import Tracking
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
        #expect(received.count == 5)
        #expect(received[3].vector == .onTarget && received[3].outcome == nil)
        #expect(await engine.outcomes.isEmpty, "A stream ending on target does not complete the hold")
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
        let epoch = ContinuousClock.now
        let offsets = [0, 50, 150, 200, 300, 500, 700, 800]
        var index = 0
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedFrames(script: frames),
            feedback: engine,
            liveComponents: [],
            guidanceNow: {
                defer { index += 1 }
                return epoch.advanced(by: .milliseconds(offsets[index]))
            }
        )

        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)

        #expect(await engine.outcomes == [.lostTracking])
        let received = await engine.received
        try #require(received.count == 9)
        for index in [1, 2, 4, 5, 7] {
            #expect(received[index].vector == nil && received[index].outcome == nil)
        }
        #expect(received[0].vector != nil && received[3].vector != nil)
        #expect(received[6].outcome == .lostTracking)
    }

    @Test("Usable AR prediction guides normally and a missing finger stays quiet")
    func predictionAndMissingFinger() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let pose = PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
            column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1)
        let target = MockSurfaceMaps.microwaveStartButton
        let frames = [
            TrackingFrame(timestamp: Date(), fingertip: PanelPoint(x: 0.1, y: 0.1), panel: pose, trackingQuality: .degraded),
            TrackingFrame(timestamp: Date(), fingertip: nil, panel: pose, trackingQuality: .good),
            TrackingFrame(timestamp: Date(), fingertip: target.bounds.center, panel: pose, trackingQuality: .good)
        ]
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedPrediction(script: frames), feedback: engine, liveComponents: [])
        await pipeline.guide(to: target)
        let received = await engine.received
        try #require(received.count == 4)
        #expect(received[0].vector != nil && received[0].outcome == nil)
        #expect(received[1].vector == nil && received[1].outcome == nil)
        #expect(received[2].vector == .onTarget && received[2].outcome == nil)
        #expect(received[3].vector == nil)
        #expect(await engine.outcomes.isEmpty)
    }

    @Test("Stop and reference replacement end an active loss episode", arguments: [false, true])
    func lossCannotOutliveSession(replace: Bool) async throws {
        let source = ControlledFrames()
        let engine = LossFeedback()
        let epoch = ContinuousClock.now
        var offset = Duration.zero
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: source, feedback: engine, liveComponents: [],
            guidanceNow: { epoch.advanced(by: offset) })
        let guiding = Task { await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton) }
        await source.waitForSubscription()
        source.send(TrackingFrame(timestamp: Date(), fingertip: PanelPoint(x: 0.1, y: 0.1),
            panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
        await engine.waitForCount(1)
        offset = .milliseconds(100)
        source.send(.lost(at: Date()))
        await engine.waitForCount(2)
        if replace {
            let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
            let reference = try PanelReference(photo: photo, detection: PanelDetection(
                referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
            await pipeline.replaceReference(with: reference)
        } else {
            await pipeline.stopGuidance()
        }
        await guiding.value
        offset = .seconds(2)
        source.send(.lost(at: Date()))
        source.finish()
        let received = await engine.received
        #expect(received.count == 3)
        #expect(received.dropFirst().allSatisfy { $0.vector == nil && $0.outcome == nil })
    }
    private func targetFrame(fingertip: PanelPoint? = MockSurfaceMaps.microwaveStartButton.bounds.center,
                             confidence: Double = 1) -> TrackingFrame {
        TrackingFrame(timestamp: Date(), fingertip: fingertip,
            panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: confidence), trackingQuality: .good)
    }

    @Test("Pipeline confirms arrival once after fresh target frames complete the hold")
    func arrivalDwell() async {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let epoch = ContinuousClock.now
        var tick = 0
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedFrames(script: (0..<16).map { _ in targetFrame() }),
            feedback: engine, liveComponents: [], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)
        let received = await engine.received
        #expect(received.count == 14)
        #expect(received.dropLast().allSatisfy { $0.vector == .onTarget && $0.outcome == nil })
        #expect(await engine.outcomes == [.arrived])
    }

    @Test("Missing finger, retreat, loss and low confidence restart a pending hold", arguments: [0, 1, 2, 3])
    func holdCancellation(reason: Int) async {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let epoch = ContinuousClock.now
        var tick = 0
        let interrupted: TrackingFrame
        switch reason {
        case 0: interrupted = targetFrame(fingertip: nil)
        case 1: interrupted = targetFrame(fingertip: PanelPoint(x: 0, y: 0))
        case 2: interrupted = .lost(at: Date())
        default: interrupted = targetFrame(confidence: 0.1)
        }
        let script = (0..<11).map { _ in targetFrame() } + [interrupted]
            + (0..<14).map { _ in targetFrame() }
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedFrames(script: script), feedback: engine, liveComponents: [], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)
        let received = await engine.received
        #expect(received.count == 26)
        #expect(received.last?.outcome == .arrived)
        #expect(received.dropLast().allSatisfy { $0.outcome != .arrived })
    }

    @Test("Stop, replacement and interruption cancel a pending hold", arguments: [0, 1, 2])
    func holdCannotOutliveSession(action: Int) async throws {
        let source = ControlledFrames()
        let engine = LossFeedback()
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: source, feedback: engine, liveComponents: [])
        let guiding = Task { await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton) }
        await source.waitForSubscription()
        source.send(targetFrame())
        await engine.waitForCount(1)
        switch action {
        case 0: await pipeline.stopGuidance()
        case 1:
            let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
            let reference = try PanelReference(photo: photo, detection: PanelDetection(
                referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
            await pipeline.replaceReference(with: reference)
        default: pipeline.interruptGuidance()
        }
        await guiding.value
        source.send(targetFrame())
        source.finish()
        let received = await engine.received
        #expect(received.first?.vector == .onTarget && received.first?.outcome == nil)
        #expect(received.last?.vector == nil)
        #expect(received.allSatisfy { $0.outcome != .arrived })
    }

    @Test("Stopping after guidance has already ended clears completed feedback")
    func stopCompletedFeedback() async {
        let engine = LiveFeedbackEngine()
        engine.setChannels(audio: false, voice: false, haptics: false)
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedFrames(script: []), feedback: engine, liveComponents: [])
        await engine.present(.outcome(.arrived, at: Date()))
        #expect(engine.didReachTarget)
        await pipeline.stopGuidance()
        #expect(!engine.didReachTarget)
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

private struct ScriptedPrediction: GuidanceTrackingSession {
    let script: [TrackingFrame]
    func frames() -> AsyncStream<TrackingFrame> { ScriptedFrames(script: script).frames() }
    func use(_ reference: PanelReference) async {}
    func registrationError() async -> PanelTrackingError? { nil }
    func hybridStatus() async -> HybridTrackingDiagnostics? {
        HybridTrackingDiagnostics(mode: .predicted, message: "Usable prediction", calibrationFrames: 12,
            source: .world, calibrationReady: true, visualVerificationAge: 0.2)
    }
}

private actor LossFeedback: FeedbackEngine {
    private(set) var received: [GuidanceState] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func present(_ state: GuidanceState) {
        received.append(state)
        let ready = waiters.filter { received.count >= $0.0 }
        waiters.removeAll { received.count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
    func waitForCount(_ target: Int) async {
        if received.count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

// Scripted sessions own no hardware; the app still exercises retirement.
private extension ScriptedPrediction {
    func stop() async {}
}
