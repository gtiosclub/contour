import CoreVideo
import Foundation
import ImageIO
import Testing
import simd
import Tracking
@testable import ContourApp

@Suite("Camera frame hub")
struct CameraFrameHubTests {
    @Test("Cancelling one subscriber leaves the other receiving frames")
    func subscribersCancelIndependently() async throws {
        let hub = CameraFrameHub()
        hub.begin(at: 0)
        let kept = hub.subscribe()
        let cancelled = hub.subscribe()
        let consumer = Task { for await _ in cancelled {} }
        consumer.cancel()
        await consumer.value
        #expect(hub.subscriberCount == 1)

        var frames = kept.makeAsyncIterator()
        #expect(hub.publish(try frame(at: 1), capturedAt: 1))
        #expect(await frames.next()?.timestamp == Date(timeIntervalSince1970: 1))
    }

    @Test("Each subscriber buffers only the newest frame")
    func slowSubscriberGetsNewestFrame() async throws {
        let hub = CameraFrameHub()
        hub.begin(at: 0)
        var frames = hub.subscribe().makeAsyncIterator()
        for time in 1...3 { hub.publish(try frame(at: TimeInterval(time)), capturedAt: TimeInterval(time)) }
        #expect(await frames.next()?.timestamp == Date(timeIntervalSince1970: 3))
    }

    @Test("Frames captured before the current run began are rejected")
    func obsoleteCallbacksAreRejected() throws {
        let hub = CameraFrameHub()
        #expect(!hub.publish(try frame(at: 1), capturedAt: 1))
        hub.begin(at: 10)
        #expect(!hub.publish(try frame(at: 9), capturedAt: 9))
        #expect(hub.publish(try frame(at: 10), capturedAt: 10))
        hub.end()
        #expect(!hub.publish(try frame(at: 11), capturedAt: 11))
    }

    @Test("Stopping finishes every stream")
    func endFinishesStreams() async {
        let hub = CameraFrameHub()
        hub.begin(at: 0)
        var first = hub.subscribe().makeAsyncIterator()
        var second = hub.subscribe().makeAsyncIterator()
        hub.end()
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
        #expect(hub.subscriberCount == 0)
        #expect(hub.current == nil)
    }

    @Test("A restart gets a fresh session identity")
    func restartChangesIdentity() {
        let hub = CameraFrameHub()
        let first = hub.begin(at: 0)
        hub.end()
        let second = hub.begin(at: 5)
        #expect(first.id != second.id)
        #expect(hub.current == second)
    }

    @Test("World data is stamped with the current run's identity")
    func worldFramesCarryRunIdentity() async throws {
        let hub = CameraFrameHub()
        let run = hub.begin(at: 0)
        var frames = hub.subscribe().makeAsyncIterator()
        let pixels = try frame(at: 1).pixelBuffer
        hub.publish(capturedAt: 1) { generation in
            let world = WorldCameraSnapshot(sessionID: generation.id, cameraToWorld: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3, imageSize: SIMD2(4, 4), normalTracking: true, planes: [])
            return CameraFrame(pixelBuffer: pixels, timestamp: Date(timeIntervalSince1970: 1),
                               orientation: .right, world: world)
        }
        #expect(await frames.next()?.world?.sessionID == run.id)
    }

    @Test("A failure report is dropped once a newer run has begun")
    func newerRunSupersedesFailure() {
        let hub = CameraFrameHub()
        let failed = hub.begin(at: 0)
        hub.end()
        #expect(!hub.isSuperseded(failed.id))
        let retried = hub.begin(at: 5)
        #expect(hub.isSuperseded(failed.id))
        #expect(!hub.isSuperseded(retried.id))
    }

    @Test("Renewing identity mid-run keeps streams and rejects the old world's frames")
    func renewalKeepsSubscribers() async throws {
        let hub = CameraFrameHub()
        hub.begin(at: 0)
        var frames = hub.subscribe().makeAsyncIterator()
        let renewed = hub.begin(at: 10)
        #expect(hub.subscriberCount == 1)

        let pixels = try frame(at: 0).pixelBuffer
        let worldFrame = { (generation: CameraFrameHub.Generation, time: TimeInterval) in
            CameraFrame(pixelBuffer: pixels, timestamp: Date(timeIntervalSince1970: time), orientation: .right,
                        world: WorldCameraSnapshot(sessionID: generation.id, cameraToWorld: matrix_identity_float4x4,
                            intrinsics: matrix_identity_float3x3, imageSize: SIMD2(4, 4),
                            normalTracking: true, planes: []))
        }
        #expect(!hub.publish(capturedAt: 9) { worldFrame($0, 9) })
        #expect(hub.publish(capturedAt: 11) { worldFrame($0, 11) })
        let received = await frames.next()
        #expect(received?.timestamp == Date(timeIntervalSince1970: 11))
        #expect(received?.world?.sessionID == renewed.id)
    }

    private func frame(at time: TimeInterval) throws -> CameraFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        try #require(status == kCVReturnSuccess)
        return CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date(timeIntervalSince1970: time))
    }
}
