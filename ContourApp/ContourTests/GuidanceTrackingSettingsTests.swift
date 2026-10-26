import ContourCore
import ContourMocks
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Guidance tracking settings and sessions")
struct GuidanceTrackingSettingsTests {
    @Test("A newer settings request wins even when old registration finishes last")
    func latestSettingsWin() async throws {
        let camera = SettingsCamera()
        let ready = ScriptedSettingsSession()
        let slow = ScriptedSettingsSession(paused: true)
        let newest = ScriptedSettingsSession()
        var sessions = [ready, slow, newest]
        let factory: GuidanceSessionFactory = { _, _, _, _ in sessions.removeFirst() }
        let pipeline = pipeline(camera: camera, factory: factory)
        let reference = try reference()
        await pipeline.replaceReference(with: reference)

        let old = pipeline.requestTrackingSettings(method: .features,
            options: FeatureTrackingOptions(excludeHighlights: false, normalizeContrast: false))
        await slow.waitForUse()
        let options = FeatureTrackingOptions(excludeHighlights: true, normalizeContrast: true)
        await pipeline.requestTrackingSettings(method: .hybrid, options: options).value
        await slow.releaseUse()
        await old.value

        #expect(pipeline.trackingMethod == .hybrid)
        #expect(pipeline.featureOptions == options)
        #expect((pipeline.tracking as? ScriptedSettingsSession) === newest)
        #expect(pipeline.panelReference?.photo.id == reference.photo.id)
        #expect(await newest.referenceID == reference.photo.id)
        #expect(pipeline.trackingReady && pipeline.trackingError == nil)
    }

    @Test("A replacement reference wins over an older asynchronous handoff")
    func latestReferenceWins() async throws {
        let camera = SettingsCamera()
        let slow = ScriptedSettingsSession(paused: true)
        let newest = ScriptedSettingsSession()
        var sessions = [slow, newest]
        let factory: GuidanceSessionFactory = { _, _, _, _ in sessions.removeFirst() }
        let pipeline = pipeline(camera: camera, factory: factory)
        let first = try reference()
        let second = try reference()

        let old = Task { await pipeline.replaceReference(with: first) }
        await slow.waitForUse()
        await pipeline.replaceReference(with: second)
        await slow.releaseUse()
        await old.value

        #expect(pipeline.panelReference?.photo.id == second.photo.id)
        #expect((pipeline.tracking as? ScriptedSettingsSession) === newest)
        #expect(await newest.referenceID == second.photo.id)
        #expect(pipeline.trackingReady)
    }

    @Test("An unsupported mode retires the old session and can be retried")
    func throwingFactoryIsExplicit() async throws {
        let camera = SettingsCamera()
        let feedback = PrintingFeedbackEngine(isPrinting: false)
        let ready = ScriptedSettingsSession(keepsStreamOpen: true)
        let retried = ScriptedSettingsSession()
        var visionSessions = [ready, retried]
        let factory: GuidanceSessionFactory = { _, method, _, _ in
            guard method == .vision else { throw GuidanceSessionFactoryError.unimplemented(method) }
            return visionSessions.removeFirst()
        }
        let pipeline = pipeline(camera: camera, factory: factory, feedback: feedback)
        let reference = try reference()
        await pipeline.replaceReference(with: reference)
        let target = try #require(reference.detection.map.buttons.first)
        let guidance = Task { await pipeline.guide(to: target) }
        await ready.waitForSubscription()

        await pipeline.requestTrackingSettings(method: .features,
            options: FeatureTrackingOptions()).value
        await guidance.value
        #expect(pipeline.trackingMethod == .features)
        #expect(!pipeline.trackingReady && !pipeline.canGuide)
        #expect(pipeline.trackingError?.contains("implemented") == true)
        #expect(pipeline.guidanceStatus.current.source == "Tracking unavailable")
        #expect(pipeline.guidanceStatus.current.message == pipeline.trackingError)
        #expect(pipeline.panelReference?.photo.id == reference.photo.id)
        await ready.send(.lost(at: Date()))
        await Task.yield()
        #expect(await feedback.received.count > 0)
        #expect(await feedback.received.last?.vector == nil)
        #expect(await feedback.received.allSatisfy { $0.vector == nil && $0.outcome == nil })

        await pipeline.requestTrackingSettings(method: .vision,
            options: FeatureTrackingOptions()).value
        #expect(pipeline.trackingReady && pipeline.trackingError == nil)
        #expect(await retried.referenceID == reference.photo.id)
        #expect(pipeline.canGuide)
    }

    @Test("Stop discards a pending session and Diagnostics gets an independent one with equal settings")
    func stopAndIndependentDiagnostics() async throws {
        let camera = SettingsCamera()
        let pending = ScriptedSettingsSession(paused: true)
        let guidanceSession = ScriptedSettingsSession()
        let diagnosticSession = ScriptedSettingsSession()
        var sessions = [pending, guidanceSession, diagnosticSession]
        var requested: [(PanelTrackingMethod, FeatureTrackingOptions, Bool)] = []
        let factory: GuidanceSessionFactory = { _, method, options, callback in
            requested.append((method, options, callback != nil))
            return sessions.removeFirst()
        }
        let pipeline = pipeline(camera: camera, factory: factory)
        let reference = try reference()
        let old = Task { await pipeline.replaceReference(with: reference) }
        await pending.waitForUse()
        await pipeline.stopGuidance()
        await pending.releaseUse()
        await old.value
        #expect(!pipeline.trackingReady)
        #expect(pipeline.panelReference?.photo.id == reference.photo.id)

        let options = FeatureTrackingOptions(excludeHighlights: false, normalizeContrast: true)
        await pipeline.requestTrackingSettings(method: .hybrid, options: options).value
        let model = TrackingDebugModel(sessionFactory: factory)
        await model.run(camera: camera, reference: reference,
                        method: pipeline.trackingMethod, options: pipeline.featureOptions)
        #expect(requested.map { $0.0 } == [.vision, .hybrid, .hybrid])
        #expect(requested[1].1 == options && requested[2].1 == options)
        #expect(!requested[1].2 && requested[2].2)
        #expect((pipeline.tracking as? ScriptedSettingsSession) === guidanceSession)
        #expect(await guidanceSession.referenceID == reference.photo.id)
        #expect(await diagnosticSession.referenceID == reference.photo.id)
    }

    private func pipeline(camera: SettingsCamera, factory: @escaping GuidanceSessionFactory,
                          feedback: PrintingFeedbackEngine = PrintingFeedbackEngine(isPrinting: false)) -> ContourPipeline {
        ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: ScriptedSettingsSession(), feedback: feedback,
            liveComponents: [.tracking], sessionFactory: factory, sessionCamera: camera)
    }

    private func reference() throws -> PanelReference {
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 32, height: 24), timestamp: Date())
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.2, y: 0.2), topRight: ImagePoint(x: 0.8, y: 0.2),
            bottomRight: ImagePoint(x: 0.8, y: 0.8), bottomLeft: ImagePoint(x: 0.2, y: 0.8))
        return try PanelReference(photo: photo, detection: PanelDetection(referencePhotoID: photo.id,
            quad: quad, map: MockSurfaceMaps.microwave))
    }
}

private actor ScriptedSettingsSession: GuidanceTrackingSession {
    private(set) var referenceID: UUID?
    private let paused: Bool
    private var enteredUse = false
    private var useWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var subscribed = false
    private var subscriptionWaiter: CheckedContinuation<Void, Never>?
    nonisolated let stream: AsyncStream<TrackingFrame>
    private let continuation: AsyncStream<TrackingFrame>.Continuation

    init(paused: Bool = false, keepsStreamOpen: Bool = false) {
        self.paused = paused
        let pair = AsyncStream<TrackingFrame>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        if !keepsStreamOpen { pair.continuation.finish() }
    }

    func use(_ reference: PanelReference) async {
        referenceID = reference.photo.id
        enteredUse = true
        useWaiter?.resume()
        useWaiter = nil
        if paused { await withCheckedContinuation { release = $0 } }
    }

    func waitForUse() async {
        if enteredUse { return }
        await withCheckedContinuation { useWaiter = $0 }
    }

    func releaseUse() {
        release?.resume()
        release = nil
    }

    func send(_ frame: TrackingFrame) { continuation.yield(frame) }

    nonisolated func frames() -> AsyncStream<TrackingFrame> {
        Task { await markSubscribed() }
        return stream
    }

    private func markSubscribed() {
        subscribed = true
        subscriptionWaiter?.resume()
        subscriptionWaiter = nil
    }

    func waitForSubscription() async {
        if subscribed { return }
        await withCheckedContinuation { subscriptionWaiter = $0 }
    }

    func registrationError() -> PanelTrackingError? { nil }
    func hybridStatus() -> HybridTrackingDiagnostics? { nil }
}

@MainActor
private final class SettingsCamera: CameraControl {
    let status = CameraStatus()
    let usesWorldTracking = false
    func start() async throws {}
    func stop() async {}
    func retry() async {}
    func setExposureBias(_ value: Float) async throws -> Float? { nil }
    func cameraFrames() async -> AsyncStream<CameraFrame> { AsyncStream { $0.finish() } }
}
