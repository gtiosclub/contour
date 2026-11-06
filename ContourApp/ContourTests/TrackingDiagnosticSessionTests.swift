import ContourCore
import ContourMocks
import CoreGraphics
import CoreVideo
import Foundation
import Testing
import Tracking
import UIKit
@testable import ContourApp

@MainActor
@Suite("Diagnostic sample and session lifecycle")
struct TrackingDiagnosticSessionTests {
    @Test("Publication uses monotonic time and keeps image, points and evidence paired")
    func pairedAndThrottled() async throws {
        var sessions: [DiagnosticSession] = []
        let clock = DiagnosticClock()
        let model = TrackingDebugModel(sessionFactory: { _, _, _, callback in
            let session = DiagnosticSession(callback: callback)
            sessions.append(session)
            return session
        }, renderImage: { frame in image(width: CVPixelBufferGetWidth(frame.pixelBuffer)) },
           displayNow: { clock.read() })
        let reference = try reference()
        let run = Task { await model.run(camera: DiagnosticCamera(), reference: reference) }
        defer { run.cancel() }
        await waitUntil { sessions.count == 1 }
        let session = try #require(sessions.first)
        let first = try sample(width: 32, source: .visual, timestamp: Date())
        await session.send(first)
        await waitUntil { model.framesProcessed == 1 }
        #expect(model.image?.width == 32)
        #expect(TrackingEvidence(sample: model.displayedFrame?.sample).source == .visual)

        // Capture dates can jump forward without permitting a faster UI update.
        let second = try sample(width: 64, source: .world, timestamp: Date().addingTimeInterval(100))
        await session.send(second)
        await waitUntil { clock.readCount >= 2 }
        #expect(model.framesProcessed == 1)
        #expect(model.image?.width == 32)
        clock.now = clock.now.advanced(by: .milliseconds(100))
        // Out-of-order capture dates must not freeze publication either.
        await session.send(try sample(width: 64, source: .world, timestamp: Date().addingTimeInterval(-100)))
        await waitUntil { model.framesProcessed == 2 }
        #expect(model.image?.width == 64)
        #expect(TrackingEvidence(sample: model.displayedFrame?.sample).source == .world)
        await session.finish()
        await run.value
        #expect(model.framesProcessed == 2)

        // A new independent session resets publication timing and retains its reference.
        clock.now = clock.now.advanced(by: .milliseconds(100))
        let replacement = Task { await model.run(camera: DiagnosticCamera(), reference: reference, method: .hybrid) }
        defer { replacement.cancel() }
        await waitUntil { sessions.count == 2 }
        let next = sessions[1]
        await next.send(second)
        await waitUntil { model.framesProcessed == 1 }
        #expect(model.image?.width == 64)
        #expect(TrackingEvidence(sample: model.displayedFrame?.sample).source == .world)
        #expect(await next.referenceID == reference.photo.id)
        #expect(model.acceptedFeaturePoints == [ImagePoint(x: 0.4, y: 0.6)])
        await next.finish()
        await replacement.value
    }

    @Test("A delayed old render cannot overwrite a replacement session or a cleared display")
    func delayedReplacement() async throws {
        var sessions: [DiagnosticSession] = []
        let gate = RenderGate()
        let model = TrackingDebugModel(sessionFactory: { _, _, _, callback in
            let session = DiagnosticSession(callback: callback)
            sessions.append(session)
            return session
        }, renderImage: { frame in
            if CVPixelBufferGetWidth(frame.pixelBuffer) == 32 { await gate.pause() }
            return image(width: CVPixelBufferGetWidth(frame.pixelBuffer))
        })
        let firstReference = try reference()
        let old = Task { await model.run(camera: DiagnosticCamera(), reference: firstReference) }
        defer { old.cancel() }
        await waitUntil { sessions.count == 1 }
        await sessions[0].send(try sample(width: 32, source: .visual))
        await gate.waitForEntry()
        let newReference = try reference()
        let current = Task { await model.run(camera: DiagnosticCamera(), reference: newReference) }
        defer { current.cancel() }
        await waitUntil { sessions.count == 2 }
        await sessions[1].send(try sample(width: 64, source: .world))
        await waitUntil { model.image?.width == 64 }
        gate.release()
        await old.value
        #expect(model.image?.width == 64)
        #expect(TrackingEvidence(sample: model.displayedFrame?.sample).source == .world)
        #expect(await sessions[1].referenceID == newReference.photo.id)
        current.cancel()
        await current.value
        #expect(model.displayedFrame == nil)
        #expect(model.acceptedFeaturePoints.isEmpty)
    }

    @Test("Cancellation while rendering cannot publish pending evidence")
    func cancelledRender() async throws {
        var session: DiagnosticSession?
        let gate = RenderGate()
        let model = TrackingDebugModel(sessionFactory: { _, _, _, callback in
            let created = DiagnosticSession(callback: callback)
            session = created
            return created
        }, renderImage: { _ in await gate.pause(); return image(width: 32) })
        let reference = try reference()
        let run = Task { await model.run(camera: DiagnosticCamera(), reference: reference) }
        await waitUntil { session != nil }
        await session?.send(try sample(width: 32, source: .world))
        await gate.waitForEntry()
        run.cancel()
        model.clearDisplayedResults()
        gate.release()
        await run.value
        #expect(model.displayedFrame == nil)
        #expect(model.framesProcessed == 0)
    }

    private func sample(width: Int, source: HybridTrackingDiagnostics.Source,
                        timestamp: Date = Date()) throws -> LiveTrackingSample {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        return LiveTrackingSample(cameraFrame: CameraFrame(pixelBuffer: try #require(buffer), timestamp: timestamp),
            frame: TrackingFrame(timestamp: timestamp, fingertip: PanelPoint(x: 0.4, y: 0.6),
                                 panel: .unknown, trackingQuality: .good), panelQuad: .fullFrame,
            imageFingertip: ImagePoint(x: 0.4, y: 0.6),
            featureDiagnostics: FeatureTrackingDiagnostics(referenceFeatures: 10, frameFeatures: 10,
                matchCount: 6, inlierCount: 4, coverage: 0.5, reprojectionError: 1,
                processingMilliseconds: 2, message: "Scripted", inlierPoints: [ImagePoint(x: 0.4, y: 0.6)],
                saturatedFraction: 0, excludedHighlightFraction: 0),
            hybridDiagnostics: HybridTrackingDiagnostics(mode: .corrected, message: "Scripted",
                calibrationFrames: 2, source: source))
    }

    private func reference() throws -> PanelReference {
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 32, height: 24), timestamp: Date())
        return try PanelReference(photo: photo, detection: PanelDetection(referencePhotoID: photo.id,
            quad: .fullFrame, map: MockSurfaceMaps.microwave))
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(predicate(), "Timed out waiting for diagnostic publication")
    }
}

@MainActor private func image(width: Int) -> CGImage? {
    UIGraphicsImageRenderer(size: CGSize(width: width, height: 24), format: {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
    }()).image { _ in }.cgImage
}

@MainActor private final class DiagnosticClock {
    var now = ContinuousClock.now
    private(set) var readCount = 0
    func read() -> ContinuousClock.Instant { readCount += 1; return now }
}

private actor DiagnosticSession: GuidanceTrackingSession {
    let callback: (@Sendable (LiveTrackingSample) -> Void)?
    nonisolated let stream: AsyncStream<TrackingFrame>
    let continuation: AsyncStream<TrackingFrame>.Continuation
    private(set) var referenceID: UUID?
    init(callback: (@Sendable (LiveTrackingSample) -> Void)?) {
        self.callback = callback
        let pair = AsyncStream<TrackingFrame>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func use(_ reference: PanelReference) { referenceID = reference.photo.id }
    func registrationError() -> PanelTrackingError? { nil }
    func hybridStatus() -> HybridTrackingDiagnostics? { nil }
    nonisolated func frames() -> AsyncStream<TrackingFrame> { stream }
    func send(_ sample: LiveTrackingSample) { callback?(sample); continuation.yield(sample.frame) }
    func finish() { continuation.finish() }
}

@MainActor private final class DiagnosticCamera: CameraControl {
    let status = CameraStatus()
    let usesWorldTracking = false
    func start() async throws {}
    func stop() async {}
    func retry() async { status.revision += 1 }
    func setExposureBias(_ value: Float) async throws -> Float? { value }
    func cameraFrames() async -> AsyncStream<CameraFrame> { AsyncStream { $0.finish() } }
}

@MainActor private final class RenderGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}

// Scripted sessions own no hardware; the app still exercises retirement.
private extension DiagnosticSession {
    func stop() async {}
}
