#if DEBUG
import ContourCore
import Foundation
import Observation
import OSLog
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
    private var lastLogTime: ContinuousClock.Instant?
    private let logger = Logger(subsystem: "edu.gatech.contour", category: "TrackingDiagnostics")

    init(processor: any TrackingFrameProcessor = FingertipFrameProcessor()) {
        self.processor = processor
        var thresholds = TrackingQualityThresholds()
        thresholds.panelRequired = false
        self.evaluator = TrackingQualityEvaluator(thresholds: thresholds)
    }

    /// Called by the screen's lifecycle task. One awaited processor invocation
    /// at a time; the camera's bounded queue drops stale waiting frames.
    func run(camera: CameraService) async {
        latest = nil
        assessment = nil
        previous = nil
        lastLogTime = nil
        framesProcessed = 0
        error = nil
        do {
            try await camera.start()
            try Task.checkCancellation()
            running = true
            for await frame in await camera.cameraFrames() {
                try Task.checkCancellation()
                let result = await processor.process(frame)
                let observation = TrackingObservation(
                    timestamp: result.timestamp,
                    fingertipConfidence: result.fingertip == nil
                        ? nil : (result.confidence ?? 0))
                let assessed = evaluator.assess(observation,
                                                previous: previous,
                                                asOf: Date())
                previous = observation
                try Task.checkCancellation()
                latest = result
                assessment = assessed
                framesProcessed += 1
                log(result)
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

    private func log(_ result: TrackingDiagnostics) {
        let now = ContinuousClock.now
        if let lastLogTime, now - lastLogTime < .milliseconds(500) { return }
        lastLogTime = now
        if let point = result.fingertip, let confidence = result.confidence {
            logger.debug("Fingertip x=\(point.x) y=\(point.y) confidence=\(confidence)")
        } else {
            logger.debug("No usable fingertip")
        }
    }
}
#endif
