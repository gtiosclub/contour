//
//  LiveTrackingSourceTests.swift
//  TrackingTests — Tracking / TrackingFrame emitter & latency
//
//  The stream end to end with a fake camera, a scripted panel tracker and a
//  scripted fingertip, so no Vision runs and these are safe on CI.
//

import ContourCore
import ContourMocks
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Tracking

@Suite("Live tracking stream")
struct LiveTrackingSourceTests {

    @Test("Production live tracking rejects an already stale capture")
    func staleCaptureIsLost() async throws {
        let samples = SampleStore()
        // Use the production evaluator here: capture age, rather than machine
        // execution speed, is the input this test intentionally exercises.
        let source = LiveTrackingSource(camera: FakeCamera(count: 1, timestampOffset: -2),
            panelTracker: scriptedPanel(), fingertipTracker: scriptedFingertip(),
            onSample: { samples.append($0) })
        await source.use(try reference())
        let frame = try #require(await collect(source.frames()).first)
        #expect(frame.trackingQuality == .lost)
        #expect(frame.fingertip == nil)
        #expect(samples.values.first?.assessment?.reason == .stale)
    }

    @Test("Visual samples use the same frame and geometry as emitted tracking")
    func visualSamplesMatchTrackingFrames() async throws {
        let samples = SampleStore()
        let source = scriptedSource(camera: FakeCamera(count: 3),
            panelTracker: scriptedPanel(lostOnFrame: 1), fingertipTracker: scriptedFingertip(),
            onSample: { samples.append($0) })
        await source.use(try reference())
        let frames = await collect(source.frames())
        let snapshots = samples.values
        #expect(snapshots.count == 3)
        guard snapshots.count == 3 else { return }
        #expect(snapshots.map(\.frame.timestamp) == frames.map(\.timestamp))
        #expect(snapshots.allSatisfy { $0.cameraFrame.timestamp == $0.frame.timestamp })
        #expect(snapshots[0].panelQuad == square)
        #expect(snapshots[0].imageFingertip == ImagePoint(x: 0.5, y: 0.5))
        #expect(snapshots[0].assessment?.quality == .good)
        #expect(snapshots[1].panelQuad == nil)
        #expect(snapshots[1].frame.fingertip == nil)
    }

    @Test("Before a panel is handed over, every frame is lost and none are dropped")
    func lostUntilThereIsAPanel() async throws {
        let source = scriptedSource(camera: FakeCamera(count: 3), panelTracker: scriptedPanel(),
                                        fingertipTracker: scriptedFingertip())

        let frames = await collect(source.frames())

        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.trackingQuality == .lost && $0.fingertip == nil })
    }

    @Test("A tracked panel and a fingertip give the fingertip's place on the panel")
    func fingertipLandsOnThePanel() async throws {
        // The panel fills the middle half of the image, and the fingertip is at
        // the image's centre, so it's at the panel's centre.
        let source = scriptedSource(camera: FakeCamera(count: 2), panelTracker: scriptedPanel(),
                                        fingertipTracker: scriptedFingertip(x: 0.5, visionY: 0.5))
        await source.use(try reference())

        let frames = await collect(source.frames())

        #expect(frames.count == 2)
        for frame in frames {
            #expect(frame.trackingQuality == .good)
            #expect(frame.panel.confidence == 1)
            let tip = try #require(frame.fingertip)
            #expect(abs(tip.x - 0.5) < 1e-6 && abs(tip.y - 0.5) < 1e-6)
        }
    }

    @Test("Vision's y-up fingertip lands the right way up on the panel")
    func fingertipYIsFlipped() async throws {
        // Vision y 0.7 (up) is image y 0.3 (down): a tenth of the image above the
        // panel's centre, which is a fifth of the panel's height above it.
        let source = scriptedSource(camera: FakeCamera(count: 1), panelTracker: scriptedPanel(),
                                        fingertipTracker: scriptedFingertip(x: 0.5, visionY: 0.7))
        await source.use(try reference())

        let tip = try #require(await collect(source.frames()).first?.fingertip)

        #expect(abs(tip.y - 0.1) < 1e-6)
    }

    @Test("No finger in view is degraded, with no fingertip")
    func noFingerIsDegraded() async throws {
        let source = scriptedSource(camera: FakeCamera(count: 1), panelTracker: scriptedPanel(),
                                        fingertipTracker: scriptedFingertip(present: false))
        await source.use(try reference())

        let frame = try #require(await collect(source.frames()).first)

        #expect(frame.trackingQuality == .degraded)
        #expect(frame.fingertip == nil)
    }

    @Test("Losing the panel is a lost frame, and the stream keeps going")
    func lostPanelIsLost() async throws {
        let source = scriptedSource(camera: FakeCamera(count: 3),
                                        panelTracker: scriptedPanel(lostOnFrame: 1),
                                        fingertipTracker: scriptedFingertip(delay: .milliseconds(200)))
        await source.use(try reference())

        let frames = await collect(source.frames())

        #expect(frames.map(\.trackingQuality) == [.good, .lost, .good])
        #expect(frames[1].fingertip == nil)
    }

    @Test("Stopping the consumer releases the camera")
    func cancellingReleasesTheCamera() async throws {
        let camera = FakeCamera(count: nil)
        let source = scriptedSource(camera: camera, panelTracker: scriptedPanel(),
                                        fingertipTracker: scriptedFingertip())
        let consumer = Task { for await _ in source.frames() {} }
        try await Task.sleep(for: .milliseconds(50))

        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(camera.released.value)
    }

    @Test("A panel that can't be tracked is lost for good, until a new one is handed over")
    func unusablePanelStaysLostUntilReplaced() async throws {
        let attempts = Counter()
        let tracker = PanelTracker { _ in
            ScriptedRectangles { image in
                // Registration (the still) fails the first time only.
                if case .still = image, attempts.next() == 0 { return nil }
                return up(square)
            }
        }
        let source = scriptedSource(camera: FakeCamera(count: 2), panelTracker: tracker,
                                        fingertipTracker: scriptedFingertip())
        await source.use(try reference())
        #expect(await collect(source.frames()).allSatisfy { $0.trackingQuality == .lost })
        #expect(await source.registrationError() == .registrationFailed)

        await source.use(try reference())
        #expect(await source.registrationError() == nil)
        #expect(await collect(source.frames()).allSatisfy { $0.trackingQuality == .good })
    }

    @Test("Each stream starts fresh from the panel")
    func eachStreamStartsFresh() async throws {
        let registrations = Counter()
        let tracker = PanelTracker { _ in
            ScriptedRectangles { image in
                if case .still = image { _ = registrations.next() }
                return up(square)
            }
        }
        let source = scriptedSource(camera: FakeCamera(count: 2), panelTracker: tracker,
                                        fingertipTracker: scriptedFingertip())
        await source.use(try reference())

        _ = await collect(source.frames())
        _ = await collect(source.frames())

        // Each stream registers the panel again (registration, then the live
        // sequence's priming, both see the reference still): 2 per stream.
        #expect(registrations.next() == 4)
    }

    @Test("Replacing the reference while fingertip detection runs discards the old point")
    func replacementDiscardsInFlightFingertip() async throws {
        let gate = DetectionGate()
        let source = scriptedSource(camera: FakeCamera(count: 1), panelTracker: scriptedPanel(),
            fingertipTracker: FingertipTracker { _ in
                await gate.pause()
                return FingertipJoint(x: 0.5, y: 0.5, confidence: 0.9)
            })
        await source.use(try reference())
        let consumer = Task { await collect(source.frames()) }
        await gate.waitUntilPaused()
        await source.use(try reference())
        await gate.resume()
        let frames = await consumer.value
        #expect(frames.count == 1)
        #expect(frames.first?.fingertip == nil)
        #expect(frames.first?.trackingQuality == .lost)
    }

    @Test("A source with no camera finishes straight away")
    func noCameraFinishes() async {
        #expect(await collect(LiveTrackingSource().frames()).isEmpty)
    }
}

// MARK: - Fakes

/// Scripted geometry/confidence tests do not assert the runner's speed.
/// Keep all other quality checks; production age handling is covered above
/// and deterministically at its thresholds in TrackingQualityTests.
private func scriptedSource(camera: any CameraFrameSource, panelTracker: PanelTracker,
                            fingertipTracker: FingertipTracker,
                            onSample: (@Sendable (LiveTrackingSample) -> Void)? = nil) -> LiveTrackingSource {
    var thresholds = TrackingQualityThresholds()
    thresholds.staleDegraded = .infinity
    thresholds.staleLost = .infinity
    return LiveTrackingSource(camera: camera, panelTracker: panelTracker,
        fingertipTracker: fingertipTracker, evaluator: TrackingQualityEvaluator(thresholds: thresholds),
        onSample: onSample)
}

private let square = PanelQuad(
    topLeft: ImagePoint(x: 0.25, y: 0.25), topRight: ImagePoint(x: 0.75, y: 0.25),
    bottomRight: ImagePoint(x: 0.75, y: 0.75), bottomLeft: ImagePoint(x: 0.25, y: 0.75))

private func collect(_ stream: AsyncStream<TrackingFrame>) async -> [TrackingFrame] {
    var frames: [TrackingFrame] = []
    for await frame in stream { frames.append(frame) }
    return frames
}

/// Emits `count` frames stamped as they're sent, with an optional age offset,
/// or keeps emitting until cancelled when `count` is nil.
private final class FakeCamera: CameraFrameSource, @unchecked Sendable {
    let count: Int?
    let timestampOffset: TimeInterval
    let released = Flag()
    init(count: Int?, timestampOffset: TimeInterval = 0) {
        self.count = count
        self.timestampOffset = timestampOffset
    }

    func cameraFrames() async -> AsyncStream<CameraFrame> {
        let count = count, released = released, timestampOffset = timestampOffset
        return AsyncStream { continuation in
            let task = Task {
                var index = 0
                while count.map({ index < $0 }) ?? true, !Task.isCancelled {
                    continuation.yield(CameraFrame(pixelBuffer: pixelBuffer(),
                        timestamp: Date().addingTimeInterval(timestampOffset)))
                    index += 1
                    // Spaced like a camera. The stream keeps only the newest
                    // frame for a slow consumer, so a burst would skip some.
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                released.set()
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.withLock { stored = true } }
    var value: Bool { lock.withLock { stored } }
}

private func pixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

/// A panel tracker that always finds `square`, except on frame `lostOnFrame`.
private func scriptedPanel(lostOnFrame: Int? = nil) -> PanelTracker {
    let counter = Counter()
    return PanelTracker { _ in
        ScriptedRectangles { image in
            guard case .frame = image else { return up(square) }
            return counter.next() == lostOnFrame ? nil : up(square)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private func up(_ quad: PanelQuad) -> VisionQuad {
    func flip(_ p: ImagePoint) -> SIMD2<Double> { SIMD2(p.x, 1 - p.y) }
    return VisionQuad(topLeft: flip(quad.topLeft), topRight: flip(quad.topRight),
                      bottomRight: flip(quad.bottomRight), bottomLeft: flip(quad.bottomLeft), confidence: 1)
}

private final class ScriptedRectangles: RectangleTracking {
    private let script: @Sendable (TrackerImage) -> VisionQuad?
    init(_ script: @escaping @Sendable (TrackerImage) -> VisionQuad?) { self.script = script }
    nonisolated(nonsending) func update(_ image: TrackerImage) async throws -> VisionQuad? { script(image) }
}

/// A fingertip at Vision's normalized (x, y-up), confidence 0.9.
private func scriptedFingertip(x: Double = 0.5, visionY: Double = 0.5, present: Bool = true,
                              delay: Duration = .zero) -> FingertipTracker {
    FingertipTracker { _ in
        if delay > .zero { try await Task.sleep(for: delay) }
        return present ? FingertipJoint(x: x, y: visionY, confidence: 0.9) : nil
    }
}

/// A decodable reference whose quad is `square`.
private func reference() throws -> PanelReference {
    let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let photo = PanelPhoto(data: data as Data, pixelSize: PixelSize(width: 64, height: 48),
                           timestamp: Date(timeIntervalSince1970: 0))
    return try PanelReference(photo: photo, detection: PanelDetection(
        referencePhotoID: photo.id, quad: square, map: MockSurfaceMaps.microwave))
}

private actor DetectionGate {
    private var paused = false
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() {
        release?.resume()
        release = nil
    }
}

private final class SampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [LiveTrackingSample] = []
    func append(_ sample: LiveTrackingSample) { lock.withLock { samples.append(sample) } }
    var values: [LiveTrackingSample] { lock.withLock { samples } }
}
