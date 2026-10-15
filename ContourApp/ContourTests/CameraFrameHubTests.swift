import CoreVideo
import Foundation
import Testing
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

    private func frame(at time: TimeInterval) throws -> CameraFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        try #require(status == kCVReturnSuccess)
        return CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date(timeIntervalSince1970: time))
    }
}
