import ContourCore
import ContourMocks
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor @Suite("Tracking session retirement")
struct TrackingRetirementTests {
    @Test("Reference/settings replacement and explicit Stop retire their actual old sessions")
    func retiresOldSessions() async throws {
        let first = RetirementSession(), next = RetirementSession()
        var sessions = [first, next]
        let initial = RetirementSession()
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(), tracking: initial,
            feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [.tracking],
            sessionFactory: { _, _, _, _ in sessions.removeFirst() }, sessionCamera: RetirementCamera())
        let reference = try reference()
        await pipeline.replaceReference(with: reference)
        #expect(await initial.stopCount == 1)
        await pipeline.requestTrackingSettings(method: .hybrid, options: FeatureTrackingOptions()).value
        #expect(await first.stopCount == 1)
        #expect(await next.stopCount == 0)
        await pipeline.stopGuidance()
        #expect(await next.stopCount == 1)
        #expect(pipeline.panelReference?.photo.id == reference.photo.id)
        #expect(pipeline.trackingReady)
    }

    @Test("A late candidate retires itself without stopping the newest session")
    func staleCandidate() async throws {
        let slow = RetirementSession(paused: true), newest = RetirementSession()
        var sessions = [slow, newest]
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(), tracking: RetirementSession(),
            feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [.tracking],
            sessionFactory: { _, _, _, _ in sessions.removeFirst() }, sessionCamera: RetirementCamera())
        let firstReference = try reference()
        let old = Task { await pipeline.replaceReference(with: firstReference) }
        await slow.waitForUse()
        let replacement = try reference()
        await pipeline.replaceReference(with: replacement)
        await slow.release()
        await old.value
        #expect(await slow.stopCount == 1)
        #expect(await newest.stopCount == 0)
        #expect(pipeline.panelReference?.photo.id == replacement.photo.id)
    }

    @Test("Diagnostics retires its independent injected source after its stream ends")
    func diagnosticsRetires() async throws {
        let session = RetirementSession()
        let model = TrackingDebugModel(sessionFactory: { _, _, _, _ in session })
        await model.run(camera: RetirementCamera(), reference: try reference())
        #expect(await session.stopCount == 1)
    }

    private func reference() throws -> PanelReference {
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 32, height: 24), timestamp: Date())
        return try PanelReference(photo: photo, detection: PanelDetection(referencePhotoID: photo.id,
            quad: .fullFrame, map: MockSurfaceMaps.microwave))
    }
}

private actor RetirementSession: GuidanceTrackingSession {
    private(set) var stopCount = 0
    let paused: Bool
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    init(paused: Bool = false) { self.paused = paused }
    func use(_ reference: PanelReference) async {
        entered = true; entry?.resume(); entry = nil
        if paused { await withCheckedContinuation { gate = $0 } }
    }
    func waitForUse() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { gate?.resume(); gate = nil }
    func stop() { stopCount += 1 }
    func registrationError() -> PanelTrackingError? { nil }
    func hybridStatus() -> HybridTrackingDiagnostics? { nil }
    nonisolated func frames() -> AsyncStream<TrackingFrame> { AsyncStream { $0.finish() } }
}

@MainActor private final class RetirementCamera: CameraControl {
    let status = CameraStatus()
    let usesWorldTracking = false
    func start() async throws {}
    func stop() async {}
    func retry() async {}
    func setExposureBias(_ value: Float) async throws -> Float? { nil }
    func cameraFrames() async -> AsyncStream<CameraFrame> { AsyncStream { $0.finish() } }
}
