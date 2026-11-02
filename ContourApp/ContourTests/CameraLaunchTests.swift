import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Launch experience")
struct CameraLaunchTests {
    private func pipeline(tracking: any TrackingSource = LaunchArrivalFrames()) -> ContourPipeline {
        let epoch = ContinuousClock.now
        var tick = 0
        return ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(), tracking: tracking,
                        feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [], guidanceNow: {
                            defer { tick += 1 }
                            return epoch.advanced(by: .milliseconds(tick * 100))
                        })
    }

    @Test("Mock launch scans and a spoken target starts guidance")
    func spokenTarget() async throws {
        let pipeline = pipeline()
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline) { map in
            VoiceRequest.Heard(text: "Start", button: map.button(labelled: "Start"))
        }
        await model.setActive(true).value
        #expect(model.ready)
        model.scan()
        await model.waitForWork()
        #expect(model.map?.buttons.count == 6)
        model.sayAButton()
        await model.waitForWork()
        #expect(pipeline.guidanceArrived)
        #expect(model.status == "Reached Start.")
        #expect(!model.busy)
    }

    @Test("Silence and unmatched speech leave the panel available for manual selection", arguments: ["", "defrost"])
    func retrySpeech(text: String) async {
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline()) { _ in
            VoiceRequest.Heard(text: text, button: nil)
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await model.waitForWork()
        #expect(model.map != nil)
        #expect(!model.busy && !model.listening)
        #expect(model.status.contains(text.isEmpty ? "Didn't hear" : "No button matching"))
    }

    @Test("Manual selection handles an ended stream without announcing arrival")
    func endedStream() async throws {
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline(tracking: EmptyLaunchFrames()))
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.choose(try #require(model.map?.buttons.first))
        await model.waitForWork()
        #expect(!model.pipeline.guidanceArrived)
        #expect(model.status.contains("Guidance ended"))
    }

    @Test("Recognition errors remain recoverable without discarding the panel")
    func recognitionError() async {
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline()) { _ in
            throw NSError(domain: "VoiceTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await model.waitForWork()
        #expect(model.error == "Microphone access denied")
        #expect(model.map != nil && !model.busy)
    }

    @Test("Replacing a panel cancels a pending voice selection")
    func changedReference() async throws {
        let gate = ListeningGate()
        let pipeline = pipeline()
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline) { _ in
            gate.started()
            try await Task.sleep(for: .seconds(60))
            return VoiceRequest.Heard(text: "Start", button: MockSurfaceMaps.microwaveStartButton)
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await gate.waitForStart()
        _ = try await pipeline.detectPanel(in: PanelPhoto(data: Data(),
            pixelSize: PixelSize(width: 100, height: 100), timestamp: Date()))
        model.referenceChanged()
        await model.waitForWork()
        #expect(!model.listening && !model.guiding && !model.busy)
        #expect(model.status.contains("Panel ready"))
    }

    @Test("Backgrounding cancels listening and foregrounding allows another request")
    func cancelAndResume() async {
        let gate = ListeningGate()
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline()) { _ in
            gate.started()
            try await Task.sleep(for: .seconds(60))
            return VoiceRequest.Heard(text: "", button: nil)
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await gate.waitForStart()
        await model.setActive(false).value
        #expect(!model.busy && !model.listening && !model.ready)
        await model.setActive(true).value
        #expect(model.ready && model.map != nil)
        model.scan()
        await model.waitForWork()
        #expect(model.map?.buttons.count == 6)
    }
    @Test("Launch selection uses the integrated feedback engine and confirmed dwell result")
    func integratedFeedback() async throws {
        let engine = LiveFeedbackEngine()
        engine.setChannels(audio: false, voice: false, haptics: false)
        let epoch = ContinuousClock.now
        var tick = 0
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: LaunchArrivalFrames(), feedback: engine, liveComponents: [.feedback], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(model.ready && model.map != nil)
        model.choose(try #require(model.map?.button(labelled: "Start")))
        await model.waitForWork()
        #expect(pipeline.guidanceArrived && engine.didReachTarget)
        #expect(model.status == "Reached Start.")
        model.stop()
        #expect(!engine.didReachTarget, "Stopping must clear confirmation before async cleanup finishes")
        await model.waitForWork()
        #expect(!pipeline.guidanceArrived)
    }

    @Test("A button belonging to an older panel cannot start guidance")
    func staleSelection() async throws {
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline())
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        let original = try #require(model.map?.buttons.first)
        let stale = SurfaceMap.Button(label: original.label, bounds: original.bounds, confidence: original.confidence)
        model.choose(stale)
        #expect(!model.busy && !model.guiding)
        #expect(!model.pipeline.guidanceArrived)
    }

}

private struct EmptyLaunchFrames: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> { AsyncStream { $0.finish() } }
}

@MainActor
private final class ListeningGate {
    private var began = false
    private var waiter: CheckedContinuation<Void, Never>?
    func started() { began = true; waiter?.resume(); waiter = nil }
    func waitForStart() async {
        if began { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private struct LaunchArrivalFrames: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { continuation in
            for _ in 0..<14 {
                continuation.yield(TrackingFrame(timestamp: Date(),
                    fingertip: MockSurfaceMaps.microwaveStartButton.bounds.center,
                    panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                        column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
            }
            continuation.finish()
        }
    }
}
