import ContourCore
import CoreVideo
import Foundation
import Testing
@testable import Tracking

@Suite("Live tracking reference and consumer lifetime")
struct LiveTrackingLifecycleTests {
    @Test("Successive consumers retain reference registration; explicit Stop resets it")
    func resumeAndStop() async throws {
        let camera = LifecycleCamera()
        let tracker = LifecyclePanel()
        let source = source(camera, tracker)
        try await source.use(FeaturePanelTrackerTests.reference())
        for index in 1...2 {
            let consumer = Task { await first(source.frames()) }
            await camera.waitForSubscriptions(index)
            await camera.send(frame())
            #expect(await consumer.value?.trackingQuality == .good)
        }
        #expect(await tracker.starts == 1)
        #expect(await tracker.stops == 0)
        await source.stop()
        #expect(await tracker.stops == 1)
        #expect(await source.hybridStatus() == nil)

        let consumer = Task { await first(source.frames()) }
        await camera.waitForSubscriptions(3)
        await camera.send(frame())
        #expect(await consumer.value?.trackingQuality == .good)
        #expect(await tracker.starts == 2)
        await source.stop()
    }

    @Test("Replacing a consumer drains old processing before starting new work")
    func replacementDrainsOldRun() async throws {
        let camera = LifecycleCamera()
        let tracker = LifecyclePanel()
        let source = source(camera, tracker)
        try await source.use(FeaturePanelTrackerTests.reference())
        await tracker.pauseNextFrame()
        let old = Task { await first(source.frames()) }
        await camera.waitForSubscriptions(1)
        await camera.send(frame())
        await tracker.waitForPause()
        let newer = Task { await first(source.frames()) }
        #expect(await old.value == nil)
        await tracker.release()
        await camera.waitForSubscriptions(2)
        await camera.send(frame())
        #expect(await newer.value?.trackingQuality == .good)
        #expect(await tracker.maximumConcurrency == 1)
        #expect(await tracker.starts == 1)
        #expect(await tracker.stops == 0)
        await source.stop()
    }

    @Test("Camera stream ending retires calibration and a later run re-registers")
    func cameraTermination() async throws {
        let camera = LifecycleCamera()
        let tracker = LifecyclePanel()
        let source = source(camera, tracker)
        try await source.use(FeaturePanelTrackerTests.reference())
        let consumer = Task { for await _ in source.frames() {} }
        await camera.waitForSubscriptions(1)
        await camera.send(frame())
        await tracker.waitForFrames(1)
        await camera.finish()
        await consumer.value
        #expect(await tracker.stops == 1)
        #expect(await source.hybridStatus() == nil)
        let restarted = Task { await first(source.frames()) }
        await camera.waitForSubscriptions(2)
        await camera.send(frame())
        #expect(await restarted.value?.trackingQuality == .good)
        #expect(await tracker.starts == 2)
        await source.stop()
    }

    @Test("A successful camera retry clears the previous registration failure")
    func successfulRetryClearsFailure() async throws {
        let camera = LifecycleCamera()
        let tracker = LifecyclePanel(failedStarts: 1)
        let source = source(camera, tracker)
        try await source.use(FeaturePanelTrackerTests.reference())
        let failed = Task { for await _ in source.frames() {} }
        await camera.waitForSubscriptions(1)
        await camera.send(frame())
        await tracker.waitForStarts(1)
        await camera.finish()
        await failed.value
        #expect(await source.registrationError() == .registrationFailed)

        let retry = Task { await first(source.frames()) }
        await camera.waitForSubscriptions(2)
        await camera.send(frame())
        #expect(await retry.value?.trackingQuality == .good)
        #expect(await source.registrationError() == nil)
        await source.stop()
    }

    private func source(_ camera: LifecycleCamera, _ panel: LifecyclePanel) -> LiveTrackingSource {
        // These scripted lifecycle tests assert registration/serialization, not
        // runner speed. Production freshness has separate threshold regressions.
        var thresholds = TrackingQualityThresholds()
        thresholds.staleDegraded = .infinity
        thresholds.staleLost = .infinity
        return LiveTrackingSource(camera: camera, panelTracker: panel,
            fingertipTracker: FingertipTracker { _ in FingertipJoint(x: 0.5, y: 0.5, confidence: 0.9) },
            evaluator: TrackingQualityEvaluator(thresholds: thresholds))
    }
    private func frame() -> CameraFrame {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &pixels)
        return CameraFrame(pixelBuffer: pixels!, timestamp: Date())
    }
    private func first(_ stream: AsyncStream<TrackingFrame>) async -> TrackingFrame? {
        for await frame in stream { return frame }
        return nil
    }
}

private actor LifecycleCamera: CameraFrameSource {
    private(set) var subscriptions = 0
    private var outputs: [AsyncStream<CameraFrame>.Continuation] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func cameraFrames() -> AsyncStream<CameraFrame> {
        subscriptions += 1
        let pair = AsyncStream<CameraFrame>.makeStream()
        outputs.append(pair.continuation)
        let ready = waiters.filter { subscriptions >= $0.0 }
        waiters.removeAll { subscriptions >= $0.0 }
        ready.forEach { $0.1.resume() }
        return pair.stream
    }
    func waitForSubscriptions(_ count: Int) async {
        if subscriptions < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
    func send(_ frame: CameraFrame) { outputs.forEach { $0.yield(frame) } }
    func finish() { outputs.forEach { $0.finish() }; outputs = [] }
}

private actor LifecyclePanel: PanelTracking {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var frames = 0
    private var concurrency = 0
    private var registered = false
    private(set) var maximumConcurrency = 0
    private var paused = false
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var frameWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var failedStarts: Int
    init(failedStarts: Int = 0) { self.failedStarts = failedStarts }
    func waitForStarts(_ count: Int) async {
        if starts < count { await withCheckedContinuation { startWaiters.append((count, $0)) } }
    }
    func waitForFrames(_ count: Int) async {
        if frames < count { await withCheckedContinuation { frameWaiters.append((count, $0)) } }
    }
    func pauseNextFrame() { paused = true }
    func waitForPause() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { gate?.resume(); gate = nil }
    func startTracking(_ reference: PanelReference) throws {
        starts += 1
        let ready = startWaiters.filter { starts >= $0.0 }
        startWaiters.removeAll { starts >= $0.0 }
        ready.forEach { $0.1.resume() }
        if failedStarts > 0 { failedStarts -= 1; throw PanelTrackingError.registrationFailed }
        registered = true
    }
    func stopTracking() { stops += 1; registered = false }
    func track(_ frame: CameraFrame) async throws -> PanelObservation {
        guard registered else { return .lost(.notStarted, at: frame.timestamp) }
        concurrency += 1
        maximumConcurrency = max(maximumConcurrency, concurrency)
        defer { concurrency -= 1 }
        frames += 1
        let ready = frameWaiters.filter { frames >= $0.0 }
        frameWaiters.removeAll { frames >= $0.0 }
        ready.forEach { $0.1.resume() }
        if paused {
            paused = false; entered = true; entry?.resume(); entry = nil
            await withCheckedContinuation { gate = $0 }
        }
        if Task.isCancelled { registered = false; throw CancellationError() }
        return .tracked(.fullFrame, confidence: 0.9, at: frame.timestamp)
    }
}
