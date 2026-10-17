import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Launch experience")
struct CameraLaunchTests {
    private func pipeline(tracking: any TrackingSource = MockTrackingSource(steps: 2, interval: .milliseconds(1))) -> ContourPipeline {
        ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(), tracking: tracking,
                        feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [])
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
