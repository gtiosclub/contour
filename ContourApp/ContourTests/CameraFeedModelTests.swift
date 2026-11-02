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

private func frame() throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
    return CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date(timeIntervalSince1970: 0))
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
