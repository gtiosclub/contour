import ContourCore
import ContourMocks
import ContourUI
import Foundation
import Testing
import Tracking
@testable import ContourApp

/// The screen's phase must follow the same states the feedback engine is
/// given, and must never outlive the session that produced it.
@MainActor
@Suite("Guidance phase")
struct GuidancePhaseTests {

    private let target = MockSurfaceMaps.microwaveStartButton

    private func frame(at fingertip: PanelPoint) -> TrackingFrame {
        TrackingFrame(timestamp: Date(), fingertip: fingertip,
            panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good)
    }
    private var awayFrame: TrackingFrame { frame(at: PanelPoint(x: 0.1, y: 0.1)) }
    private var targetFrame: TrackingFrame { frame(at: target.bounds.center) }

    private func makePipeline(_ source: any TrackingSource, _ feedback: PhaseFeedback,
                              clock: PhaseTestClock) -> ContourPipeline {
        ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(), tracking: source,
            feedback: feedback, liveComponents: [], guidanceNow: { clock.now })
    }

    /// Sends `frame` and waits until feedback has been given its state.
    private func send(_ frame: TrackingFrame, to source: PhaseFrames, feedback: PhaseFeedback,
                      expecting count: Int) async {
        source.send(frame)
        await feedback.waitForCount(count)
    }

    /// The phase shown matches the last state the feedback engine received.
    private func expectAgreement(_ pipeline: ContourPipeline, _ feedback: PhaseFeedback,
                                 sourceLocation: SourceLocation = #_sourceLocation) async {
        let last = await feedback.received.last
        #expect(last.map { GuidancePhase($0) } == pipeline.guidancePhase, sourceLocation: sourceLocation)
    }

    @Test("No session has run, then a frame away from the target is guiding")
    func guiding() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let pipeline = makePipeline(source, feedback, clock: PhaseTestClock())
        #expect(pipeline.guidancePhase == nil)
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        await send(awayFrame, to: source, feedback: feedback, expecting: 1)
        #expect(pipeline.guidancePhase == .guiding)
        await expectAgreement(pipeline, feedback)
        source.finish()
        await guiding.value
        #expect(pipeline.guidancePhase == .stopped, "Ending without arriving shows stopped")
    }

    @Test("On target is holding until the hold completes")
    func holdingBeforeConfirmation() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let clock = PhaseTestClock()
        let pipeline = makePipeline(source, feedback, clock: clock)
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        for index in 0..<12 {
            clock.offset = .milliseconds(index * 100)
            await send(targetFrame, to: source, feedback: feedback, expecting: index + 1)
            #expect(pipeline.guidancePhase == .holding)
            await expectAgreement(pipeline, feedback)
        }
        #expect(!pipeline.guidanceArrived)
        source.finish()
        await guiding.value
    }

    @Test("A confirmed hold is arrived and stays arrived after the loop ends")
    func confirmedArrival() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let clock = PhaseTestClock()
        let pipeline = makePipeline(source, feedback, clock: clock)
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        // Frame 13 arrives at 1.3 s, past the 1.25 s hold.
        for index in 0..<14 {
            clock.offset = .milliseconds(index * 100)
            await send(targetFrame, to: source, feedback: feedback, expecting: index + 1)
            if index < 13 { #expect(pipeline.guidancePhase == .holding) }
        }
        await guiding.value
        #expect(pipeline.guidanceArrived)
        #expect(pipeline.guidancePhase == .arrived)
        #expect(await feedback.received.last?.outcome == .arrived)
        await expectAgreement(pipeline, feedback)
    }

    @Test("Slipping off the target mid-hold returns to guiding and the hold starts over")
    func holdCancellation() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let clock = PhaseTestClock()
        let pipeline = makePipeline(source, feedback, clock: clock)
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        var presented = 0
        func step(_ ms: Int, _ frame: TrackingFrame) async {
            clock.offset = .milliseconds(ms)
            presented += 1
            await send(frame, to: source, feedback: feedback, expecting: presented)
        }
        for ms in stride(from: 0, through: 1000, by: 100) { await step(ms, targetFrame) }
        #expect(pipeline.guidancePhase == .holding)
        await step(1100, awayFrame)
        #expect(pipeline.guidancePhase == .guiding, "Leaving the target cancels the pending hold")
        // 1.2 s back on target is not enough: the earlier second does not count.
        for ms in stride(from: 1200, through: 2400, by: 100) {
            await step(ms, targetFrame)
            #expect(pipeline.guidancePhase == .holding)
        }
        #expect(!pipeline.guidanceArrived)
        await step(2500, targetFrame)
        await guiding.value
        #expect(pipeline.guidancePhase == .arrived)
        #expect(await feedback.received.filter { $0.outcome == .arrived }.count == 1)
    }

    @Test("Try again after an ended session guides to the same button")
    func retryAfterStopped() async throws {
        var tick = 0
        let epoch = ContinuousClock.now
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: RetryFrames(arrival: (0..<14).map { _ in targetFrame }),
            feedback: PhaseFeedback(), liveComponents: [], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        let start = try #require(model.map?.button(labelled: "Start"))
        model.choose(start)
        await model.waitForWork()
        #expect(pipeline.guidancePhase == .stopped)
        let phase = try #require(pipeline.guidancePhase)
        #expect(GuidanceScreenContent(phase: phase, targetLabel: "Start").actions.first == .retry)
        // What the card's Try again button does.
        let retryTarget = try #require(model.guidanceTarget)
        #expect(retryTarget.id == start.id)
        model.choose(retryTarget)
        await model.waitForWork()
        #expect(pipeline.guidanceArrived)
        #expect(pipeline.guidancePhase == .arrived)
    }

    @Test("Loss is searching, then lost once announced, then guiding again on recovery")
    func lossAndRecovery() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let clock = PhaseTestClock()
        let pipeline = makePipeline(source, feedback, clock: clock)
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        await send(awayFrame, to: source, feedback: feedback, expecting: 1)
        #expect(pipeline.guidancePhase == .guiding)

        clock.offset = .milliseconds(100)
        await send(.lost(at: Date()), to: source, feedback: feedback, expecting: 2)
        #expect(pipeline.guidancePhase == .searching, "A short gap is not announced")
        await expectAgreement(pipeline, feedback)

        clock.offset = .milliseconds(500)
        await send(.lost(at: Date()), to: source, feedback: feedback, expecting: 3)
        #expect(pipeline.guidancePhase == .lostTracking)
        await expectAgreement(pipeline, feedback)

        // A further lost frame presents nothing, so the next state presented
        // is the recovery.
        source.send(.lost(at: Date()))
        clock.offset = .milliseconds(700)
        await send(awayFrame, to: source, feedback: feedback, expecting: 4)
        #expect(pipeline.guidancePhase == .guiding)
        await expectAgreement(pipeline, feedback)

        source.finish()
        await guiding.value
        #expect(pipeline.guidancePhase == .stopped)
    }

    @Test("A tracked panel with no fingertip is finding the finger, not searching")
    func missingFinger() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let clock = PhaseTestClock()
        let pipeline = makePipeline(source, feedback, clock: clock)
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        await send(awayFrame, to: source, feedback: feedback, expecting: 1)
        clock.offset = .milliseconds(100)
        let noFinger = TrackingFrame(timestamp: Date(), fingertip: nil, panel: awayFrame.panel, trackingQuality: .good)
        await send(noFinger, to: source, feedback: feedback, expecting: 2)
        #expect(pipeline.guidancePhase == .findingFinger)
        #expect(await feedback.received.last?.vector == nil, "Feedback still gets the same empty state")
        clock.offset = .milliseconds(200)
        await send(awayFrame, to: source, feedback: feedback, expecting: 3)
        #expect(pipeline.guidancePhase == .guiding)
        clock.offset = .milliseconds(300)
        await send(.lost(at: Date()), to: source, feedback: feedback, expecting: 4)
        #expect(pipeline.guidancePhase == .searching, "A lost panel is still searching")
        source.finish()
        await guiding.value
    }

    @Test("Only brief gaps and slipping off the target wait before showing")
    func settleRule() {
        typealias Settle = SettledGuidanceStateView
        #expect(Settle.settleDelay(from: .guiding, to: .findingFinger) != nil)
        #expect(Settle.settleDelay(from: .guiding, to: .searching) != nil)
        #expect(Settle.settleDelay(from: .holding, to: .guiding) != nil)
        #expect(Settle.settleDelay(from: .findingFinger, to: .guiding) == nil)
        #expect(Settle.settleDelay(from: .guiding, to: .holding) == nil)
        #expect(Settle.settleDelay(from: .guiding, to: .lostTracking) == nil)
        #expect(Settle.settleDelay(from: .holding, to: .arrived) == nil)
    }

    @Test("Stopping mid-session clears the phase and later frames cannot restore it")
    func stopMidSession() async {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let pipeline = makePipeline(source, feedback, clock: PhaseTestClock())
        let guiding = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        await send(awayFrame, to: source, feedback: feedback, expecting: 1)
        #expect(pipeline.guidancePhase == .guiding)
        await pipeline.stopGuidance()
        await guiding.value
        #expect(pipeline.guidancePhase == nil)
        source.send(targetFrame)
        source.finish()
        await Task.yield()
        #expect(pipeline.guidancePhase == nil)
    }

    @Test("A replacement session never shows the old session's phase")
    func replacementSession() async throws {
        let source = PhaseFrames()
        let feedback = PhaseFeedback()
        let pipeline = makePipeline(source, feedback, clock: PhaseTestClock())
        let first = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(1)
        await send(targetFrame, to: source, feedback: feedback, expecting: 1)
        #expect(pipeline.guidancePhase == .holding)

        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
        let reference = try PanelReference(photo: photo, detection: PanelDetection(
            referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
        await pipeline.replaceReference(with: reference)
        await first.value
        #expect(pipeline.guidancePhase == nil, "No session has run for the new panel")

        let presentedBefore = await feedback.received.count
        let second = Task { await pipeline.guide(to: target) }
        await source.waitForSubscriptions(2)
        #expect(pipeline.guidancePhase == nil)
        await send(awayFrame, to: source, feedback: feedback, expecting: presentedBefore + 1)
        #expect(pipeline.guidancePhase == .guiding)
        await expectAgreement(pipeline, feedback)
        source.finish()
        await second.value
    }

    @Test("A registration failure ends guidance with a plain next step")
    func registrationFailure() async {
        let session = FailingRegistrationSession()
        let feedback = PhaseFeedback()
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: session, feedback: feedback, liveComponents: [])
        let guiding = Task { await pipeline.guide(to: target) }
        await session.waitForSubscription()
        session.send(awayFrame)
        // The session ends by itself; the stream is never finished.
        await guiding.value
        #expect(pipeline.guidancePhase == .cannotLockOn, "Not replaced by stopped")
        let content = GuidanceScreenContent(phase: .cannotLockOn, targetLabel: "Start")
        #expect(!content.message.contains("Vision"), "No developer wording on screen")
        #expect(content.actions.first == .scanAgain)
        // No guidance reached feedback; only the closing silence did.
        let received = await feedback.received
        #expect(received.count == 1 && received[0].vector == nil && received[0].outcome == nil)
        #expect(pipeline.trackingError != nil, "The developer reason stays for diagnostics")
    }

    @Test("VoiceOver stays quiet for the moments the feedback voice speaks")
    func speechOwnership() {
        for phase: GuidancePhase in [.guiding, .arrived, .lostTracking, .cannotLockOn] {
            #expect(LiveCameraView.feedbackVoiceSpeaks(phase))
        }
        for phase: GuidancePhase in [.stopped, .notFound, .lowConfidence, .holding, .searching, .findingFinger] {
            #expect(!LiveCameraView.feedbackVoiceSpeaks(phase))
        }
    }
}

@MainActor
private final class PhaseTestClock {
    private let epoch = ContinuousClock.now
    var offset = Duration.zero
    var now: ContinuousClock.Instant { epoch.advanced(by: offset) }
}

/// Hands each subscriber a fresh stream; frames go to the newest one.
private final class PhaseFrames: TrackingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<TrackingFrame>.Continuation] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func frames() -> AsyncStream<TrackingFrame> {
        let pair = AsyncStream<TrackingFrame>.makeStream()
        let ready = lock.withLock {
            continuations.append(pair.continuation)
            let ready = waiters.filter { continuations.count >= $0.0 }
            waiters.removeAll { continuations.count >= $0.0 }
            return ready
        }
        for waiter in ready { waiter.1.resume() }
        return pair.stream
    }
    func waitForSubscriptions(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if continuations.count >= count { continuation.resume() } else { waiters.append((count, continuation)) }
            }
        }
    }
    func send(_ frame: TrackingFrame) { _ = lock.withLock { continuations.last }?.yield(frame) }
    func finish() { lock.withLock { continuations }.forEach { $0.finish() } }
}

/// Ends the first session at once; later sessions play `arrival`.
private final class RetryFrames: TrackingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions = 0
    let arrival: [TrackingFrame]
    init(arrival: [TrackingFrame]) { self.arrival = arrival }
    func frames() -> AsyncStream<TrackingFrame> {
        let first = lock.withLock { subscriptions += 1; return subscriptions == 1 }
        let script = first ? [] : arrival
        return AsyncStream { continuation in
            script.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private final class FailingRegistrationSession: GuidanceTrackingSession, @unchecked Sendable {
    private let source = PhaseFrames()
    func frames() -> AsyncStream<TrackingFrame> { source.frames() }
    func waitForSubscription() async { await source.waitForSubscriptions(1) }
    func send(_ frame: TrackingFrame) { source.send(frame) }
    func finish() { source.finish() }
    func use(_ reference: PanelReference) async {}
    func registrationError() async -> PanelTrackingError? { .registrationFailed }
    func hybridStatus() async -> HybridTrackingDiagnostics? { nil }
    func stop() async {}
}

private actor PhaseFeedback: FeedbackEngine {
    private(set) var received: [GuidanceState] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func present(_ state: GuidanceState) {
        received.append(state)
        let ready = waiters.filter { received.count >= $0.0 }
        waiters.removeAll { received.count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
    func waitForCount(_ target: Int) async {
        if received.count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}
