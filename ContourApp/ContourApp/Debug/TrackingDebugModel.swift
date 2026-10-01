#if DEBUG
import Foundation
import Observation
import Tracking

@MainActor
@Observable
final class TrackingDebugModel {
    private(set) var latest: TrackingDiagnostics?
    private(set) var assessment: TrackingAssessment?
    private(set) var framesProcessed = 0
    private(set) var error: String?
    private(set) var running = false
    private let processor: any TrackingFrameProcessor
    private let evaluator: TrackingQualityEvaluator
    private var previous: TrackingObservation?
    private var referenceGeneration: UInt64 = 0

    init(processor: any TrackingFrameProcessor = UnimplementedFrameProcessor()) {
        self.processor = processor
        var thresholds = TrackingQualityThresholds()
        thresholds.panelRequired = false
        self.evaluator = TrackingQualityEvaluator(thresholds: thresholds)
    }

    /// Clear this screen's diagnostic output when the prepared reference is
    /// replaced. A processor already working on a frame cannot publish its
    /// old result after the generation changes.
    func clearDisplayedResults() {
        referenceGeneration &+= 1
        latest = nil
        assessment = nil
        previous = nil
        framesProcessed = 0
        error = nil
    }

    func accept(_ result: TrackingDiagnostics, from generation: UInt64) {
        guard generation == referenceGeneration else { return }
        let observation = TrackingObservation(
            timestamp: result.timestamp,
            fingertipConfidence: result.fingertip == nil
                ? nil : (result.confidence ?? 0))
        assessment = evaluator.assess(observation, previous: previous, asOf: Date())
        previous = observation
        latest = result
        framesProcessed += 1
    }

    /// Called by the screen's lifecycle task. One awaited processor invocation
    /// at a time; the camera's bounded queue drops stale waiting frames.
    func run(camera: CameraService) async {
        clearDisplayedResults()
        do {
            try await camera.start()
            try Task.checkCancellation()
            running = true
            for await frame in await camera.cameraFrames() {
                try Task.checkCancellation()
                let generation = referenceGeneration
                let result = await processor.process(frame)
                try Task.checkCancellation()
                accept(result, from: generation)
            }
        } catch is CancellationError {
            // Normal navigation/background lifecycle.
        } catch {
            self.error = error.localizedDescription
        }
        running = false
        latest = nil
        assessment = nil
        await camera.stop()
    }
}
#endif
