import ContourCore
import ContourMocks
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Guidance status lifecycle")
struct GuidanceStatusLifecycleTests {
    @Test("Display publication never gates frame feedback and Stop clears pending evidence")
    func feedbackAndStop() async {
        let source = StatusTestSession()
        let feedback = StatusTestFeedback()
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: source, feedback: feedback, liveComponents: [])
        let guiding = Task { await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton) }
        await source.waitForSubscription()
        for _ in 0..<20 { await source.sendFrame() }
        await feedback.waitForCount(20)
        // No display tick has run, but every frame has reached feedback.
        #expect(pipeline.guidanceStatus.current == .waiting)
        pipeline.guidanceStatus.publishIfDue()
        #expect(pipeline.guidanceStatus.current.source == "AR prediction")
        await source.sendFrame()
        await feedback.waitForCount(21)
        await pipeline.stopGuidance()
        await guiding.value
        pipeline.guidanceStatus.publishIfDue(at: ContinuousClock.now.advanced(by: .seconds(1)))
        #expect(pipeline.guidanceStatus.current == .stopped)
        #expect(pipeline.hybridStatus == nil)
    }

    @Test("A status read completing after reference replacement cannot republish the old session")
    func replacementRejectsDelayedEvidence() async throws {
        let source = StatusTestSession(holdStatus: true)
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: source, feedback: StatusTestFeedback(), liveComponents: [])
        let guiding = Task { await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton) }
        await source.waitForSubscription()
        await source.sendFrame()
        await source.waitForStatusRead()
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
        let reference = try PanelReference(photo: photo, detection: PanelDetection(
            referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
        let replacing = Task { await pipeline.replaceReference(with: reference) }
        // Wait until the replacement synchronously clears old evidence.
        while pipeline.panelReference?.photo.id != reference.photo.id { await Task.yield() }
        await source.releaseStatus()
        await replacing.value
        await guiding.value
        pipeline.guidanceStatus.publishIfDue(at: ContinuousClock.now.advanced(by: .seconds(1)))
        #expect(pipeline.guidanceStatus.current == .waiting)
        #expect(pipeline.hybridStatus == nil)
    }
}

private actor StatusTestSession: GuidanceTrackingSession {
    nonisolated let stream: AsyncStream<TrackingFrame>
    private let continuation: AsyncStream<TrackingFrame>.Continuation
    private var subscribed = false
    private var subscriptionWaiter: CheckedContinuation<Void, Never>?
    private var statusRead = false
    private var statusWaiter: CheckedContinuation<Void, Never>?
    private var statusRelease: CheckedContinuation<Void, Never>?
    private let holdStatus: Bool

    init(holdStatus: Bool = false) {
        self.holdStatus = holdStatus
        let pair = AsyncStream<TrackingFrame>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }
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
    func sendFrame() {
        continuation.yield(TrackingFrame(timestamp: Date(), fingertip: PanelPoint(x: 0.01, y: 0.01),
            panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
    }
    func use(_ reference: PanelReference) {}
    func registrationError() -> PanelTrackingError? { nil }
    func hybridStatus() async -> HybridTrackingDiagnostics? {
        statusRead = true
        statusWaiter?.resume()
        statusWaiter = nil
        if holdStatus { await withCheckedContinuation { statusRelease = $0 } }
        return HybridTrackingDiagnostics(mode: .predicted, message: "Scripted prediction",
            calibrationFrames: 12, source: .world, calibrationReady: true, visualVerificationAge: 0.5)
    }
    func waitForStatusRead() async {
        if statusRead { return }
        await withCheckedContinuation { statusWaiter = $0 }
    }
    func releaseStatus() { statusRelease?.resume(); statusRelease = nil }
}

private actor StatusTestFeedback: FeedbackEngine {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func present(_ state: GuidanceState) {
        count += 1
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
    func waitForCount(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}
