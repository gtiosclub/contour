import ContourCore
import CoreVideo
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Camera feed preview")
struct CameraFeedModelTests {
    @Test("A finished stream clears the preview and a new run resubscribes")
    func previewReconnectsAfterRestart() async throws {
        let camera = ScriptedFrameSource()
        let model = CameraFeedModel()

        let firstRun = Task { await model.run(camera: camera, framesPerSecond: 1000) }
        let first = await camera.nextStream()
        first.yield(try frame())
        try await waitUntil { model.image != nil }

        // Camera stopped: the old image must not stay up looking live.
        first.finish()
        await firstRun.value
        #expect(model.image == nil)

        let secondRun = Task { await model.run(camera: camera, framesPerSecond: 1000) }
        let second = await camera.nextStream()
        second.yield(try frame())
        try await waitUntil { model.image != nil }
        #expect(await camera.subscriptions == 2)

        secondRun.cancel()
        await secondRun.value
    }

    @Test("The target outline draws on its matching image and is dropped when the camera gets ahead")
    func showsFreshTrackingImage() async throws {
        let camera = ScriptedFrameSource()
        let model = CameraFeedModel()
        let trackedFrame = try frame(width: 24, height: 32)
        let sample = LiveTrackingSample(
            cameraFrame: trackedFrame,
            frame: TrackingFrame(timestamp: trackedFrame.timestamp, fingertip: nil,
                                 panel: .unknown, trackingQuality: .degraded),
            panelQuad: PanelQuad(topLeft: ImagePoint(x: 0.2, y: 0.2), topRight: ImagePoint(x: 0.8, y: 0.2),
                                 bottomRight: ImagePoint(x: 0.8, y: 0.8), bottomLeft: ImagePoint(x: 0.2, y: 0.8))
        )
        let bounds = PanelRect(origin: PanelPoint(x: 0.25, y: 0.25), width: 0.5, height: 0.25)
        let button = SurfaceMap.Button(label: " Start ", bounds: bounds, confidence: 1)
        let target = try #require(GuidanceTargetFrame(sample: sample, target: button, sessionID: 42))
        #expect(target.marker.title == "Start")
        let unlabelled = SurfaceMap.Button(label: nil, bounds: bounds, confidence: 1)
        #expect(GuidanceTargetFrame(sample: sample, target: unlabelled, sessionID: 42)?.marker.title == "Unlabelled button")
        let corner = try #require(target.marker.corners.first)
        #expect(abs(corner.x - 0.35) < 0.0001 && abs(corner.y - 0.35) < 0.0001)
        let lost = LiveTrackingSample(cameraFrame: trackedFrame, frame: .lost(at: trackedFrame.timestamp))
        #expect(GuidanceTargetFrame(sample: lost, target: button, sessionID: 42) == nil)

        let run = Task { await model.run(camera: camera, framesPerSecond: 1000, targetFrame: { target }) }
        let stream = await camera.nextStream()
        defer { stream.finish() }

        stream.yield(try frame(time: 0.05))
        try await waitUntil { model.preview?.marker?.sessionID == 42 }
        #expect(model.image?.width == 24)
        #expect(model.preview?.marker?.title == "Start")

        stream.yield(try frame(time: 0.5))
        try await waitUntil { model.image?.width == 32 }
        #expect(model.preview?.marker == nil)
        stream.finish()
        await run.value
    }
}

/// Hands out a fresh stream per subscription, which the test drives by hand.
private actor ScriptedFrameSource: CameraFrameSource {
    private(set) var subscriptions = 0
    private var pending: [AsyncStream<CameraFrame>.Continuation] = []
    private var waiters: [CheckedContinuation<AsyncStream<CameraFrame>.Continuation, Never>] = []

    func cameraFrames() -> AsyncStream<CameraFrame> {
        subscriptions += 1
        let (stream, continuation) = AsyncStream<CameraFrame>.makeStream()
        if waiters.isEmpty {
            pending.append(continuation)
        } else {
            waiters.removeFirst().resume(returning: continuation)
        }
        return stream
    }

    /// The next subscription's continuation, waiting for it if needed.
    func nextStream() async -> AsyncStream<CameraFrame>.Continuation {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private func frame(width: Int = 32, height: Int = 24, time: TimeInterval = 0) throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    return CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date(timeIntervalSince1970: time))
}

/// Yields instead of sleeping, so the test stays deterministic and fast.
@MainActor
private func waitUntil(_ condition: () -> Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
    var attempts = 0
    while !condition() && attempts < 100_000 {
        attempts += 1
        await Task.yield()
    }
    try #require(condition(), sourceLocation: sourceLocation)
}
