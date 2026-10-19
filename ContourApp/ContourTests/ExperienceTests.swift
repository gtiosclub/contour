//
//  ExperienceTests.swift
//  ContourTests
//
//  The app flow's wiring decisions: what a scan result leads to, how a
//  guidance session that ended by itself finished, the pipeline's observable
//  guidance, the Simulator's aimable mock walk, and the DEBUG demo stages.
//

import ContourCore
import ContourMocks
import ContourUI
import Foundation
import Testing
@testable import ContourApp

@Suite("Experience policy")
struct ExperiencePolicyTests {

    @Test("a confident, trackable panel with controls goes to selection")
    func select() {
        #expect(ExperiencePolicy.scanResult(map: MockSurfaceMaps.microwave, canGuide: true) == .select)
    }

    @Test("an untrackable outline goes back to aiming with the Surface message")
    func untrackable() {
        guard case .retry(let reason) = ExperiencePolicy.scanResult(map: MockSurfaceMaps.microwave,
                                                                     canGuide: false) else {
            Issue.record("expected a retry")
            return
        }
        #expect(reason.hasPrefix("Surface did not return a trackable panel outline."))
    }

    @Test("no controls goes back to aiming; a barely-there panel is low confidence")
    func emptyAndUnsure() {
        if case .retry = ExperiencePolicy.scanResult(map: SurfaceMap(buttons: [], confidence: 0.9), canGuide: true) {
        } else {
            Issue.record("an empty map should retry")
        }
        var faint = MockSurfaceMaps.microwave
        faint.confidence = 0.1
        #expect(ExperiencePolicy.scanResult(map: faint, canGuide: true) == .lowConfidence)
    }

    @Test("guidance that ends by itself finishes as arrived, low confidence, or lost")
    func endedOutcome() {
        #expect(ExperiencePolicy.outcome(afterGuidanceEndedWith: .arrived) == .arrived)
        #expect(ExperiencePolicy.outcome(afterGuidanceEndedWith: .lowConfidence) == .lowConfidence)
        #expect(ExperiencePolicy.outcome(afterGuidanceEndedWith: .lostTracking) == .lostTracking)
        #expect(ExperiencePolicy.outcome(afterGuidanceEndedWith: nil) == .lostTracking)
    }

    @Test("a tracking error becomes one plain scan-again line; no error, no line")
    func trackingProblem() {
        #expect(ExperiencePolicy.trackingProblem(for: nil) == nil)
        let line = ExperiencePolicy.trackingProblem(
            for: "Vision could not track the marked panel in the reference photo. Capture again and mark its actual boundary.")
        #expect(line?.contains("Scan again") == true)
        #expect(line?.contains("reference") == false)
    }

    @Test("the drawn finger sits back along the guidance vector from the target")
    func fingertip() throws {
        let start = MockSurfaceMaps.microwaveStartButton
        let finger = PanelPoint(x: 0.2, y: 0.9)
        let state = MockGuidance.state(fingertip: finger, target: start.bounds.center, timestamp: Date())
        let drawn = try #require(ExperiencePolicy.approximateFingertip(target: start, guidance: state))
        #expect(abs(drawn.x - finger.x) < 1e-9 && abs(drawn.y - finger.y) < 1e-9)
        #expect(ExperiencePolicy.approximateFingertip(target: start, guidance: nil) == nil)
    }
}

@MainActor
@Suite("Observable guidance")
struct ObservableGuidanceTests {

    @Test("the pipeline exposes the latest guidance and the arrival")
    func latestAndArrival() async {
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: MockTrackingSource(steps: 3, interval: .milliseconds(1)),
            feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [])
        #expect(pipeline.latestGuidance == nil)
        await pipeline.guide(to: MockSurfaceMaps.microwaveStartButton)
        #expect(pipeline.latestGuidance?.outcome == .arrived)
        #expect(pipeline.lastOutcome == .arrived)
    }

    @Test("the mock pipeline walks to whichever control was chosen")
    func aimableWalk() async throws {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: AimableMockTracking(steps: 4, interval: .milliseconds(1)),
            feedback: engine, liveComponents: [])
        let popcorn = try #require(MockSurfaceMaps.microwave.button(labelled: "Popcorn"))
        await pipeline.guide(to: popcorn)
        #expect(await engine.outcomes.last == .arrived)
        #expect(pipeline.lastOutcome == .arrived)
    }

    @Test("the Simulator's mock pipeline uses the aimable walk")
    func mockIsAimable() {
        #expect(ContourPipeline.mock().tracking is AimableMockTracking)
    }
}

@MainActor
@Suite("The whole flow on the mock pipeline")
struct ExperienceFlowTests {

    /// Polls until `condition` holds, failing after `seconds`.
    private func waitFor(_ what: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("launch → scan → choose Start → guided in → arrived")
    func scanChooseArrive() async throws {
        let model = ExperienceModel(pipeline: .mock(), camera: CameraService())
        let running = Task { await model.run() }
        defer { running.cancel() }

        try await waitFor("the camera screen") { model.stage == .acquiringPanel }
        model.scan()
        try await waitFor("the controls") { model.stage.kind == .selectingTarget }
        #expect(model.map == MockSurfaceMaps.microwave)

        model.choose(MockSurfaceMaps.microwaveStartButton)
        try await waitFor("guidance") { model.stage == .guiding(MockSurfaceMaps.microwaveStartButton) }
        try await waitFor("arrival") { model.stage == .finished(.arrived) }
        #expect(model.targetName == "Start")
        #expect(model.canGuideAgain)
    }

    @Test("Stop goes back to the controls on the same panel")
    func stopReturnsToSelection() async throws {
        let model = ExperienceModel(pipeline: .mock(), camera: CameraService())
        let running = Task { await model.run() }
        defer { running.cancel() }

        try await waitFor("the camera screen") { model.stage == .acquiringPanel }
        model.scan()
        try await waitFor("the controls") { model.stage.kind == .selectingTarget }
        model.choose(MockSurfaceMaps.microwaveStartButton)
        try await waitFor("guidance") { model.stage.kind == .guiding }
        model.stopGuiding()
        try await waitFor("the controls again") { model.stage == .selectingTarget(MockSurfaceMaps.microwave) }
        model.rescan()
        try await waitFor("the camera again") { model.stage == .acquiringPanel }
    }

    @Test("Scan again from the guide screen goes back to the camera")
    func rescanWhileGuiding() async throws {
        let model = ExperienceModel(pipeline: .mock(), camera: CameraService())
        let running = Task { await model.run() }
        defer { running.cancel() }

        try await waitFor("the camera screen") { model.stage == .acquiringPanel }
        model.scan()
        try await waitFor("the controls") { model.stage.kind == .selectingTarget }
        model.choose(MockSurfaceMaps.microwaveStartButton)
        try await waitFor("guidance") { model.stage.kind == .guiding }
        model.rescan()
        try await waitFor("the camera again") { model.stage == .acquiringPanel }
        #expect(model.trackingProblem == nil)
    }
}

#if DEBUG
@Suite("Screenshot demo stages")
struct DemoStageTests {

    @Test("every demo stage is reached through legal moves", arguments: DemoStage.allCases)
    func routesAreLegal(stage: DemoStage) {
        var current = GuidanceFlowStage.idle
        for next in stage.route {
            #expect(GuidanceFlow.isLegal(from: current, to: next), "\(stage): \(current) → \(next)")
            current = next
        }
    }

    @Test("the launch argument names the stage")
    func parsesLaunchArgument() throws {
        let defaults = try #require(UserDefaults(suiteName: "ContourDemoStageTests"))
        defer { defaults.removePersistentDomain(forName: "ContourDemoStageTests") }
        #expect(DemoStage.fromLaunchArguments(defaults) == nil)
        defaults.set("lostTracking", forKey: DemoStage.launchArgument)
        #expect(DemoStage.fromLaunchArguments(defaults) == .lostTracking)
        defaults.set("nonsense", forKey: DemoStage.launchArgument)
        #expect(DemoStage.fromLaunchArguments(defaults) == nil)
    }
}
#endif
