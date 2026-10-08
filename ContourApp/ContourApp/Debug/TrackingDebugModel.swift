#if DEBUG
import CoreGraphics
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
    private(set) var image: CGImage?
    private(set) var panelQuad: PanelQuad?
    private(set) var trackingFrame: TrackingFrame?
    private(set) var latency: TimeInterval?
    private let worker: DiagnosticWorker
    private let renderer = FrameImageRenderer()
    private let evaluator: TrackingQualityEvaluator
    private var previous: TrackingObservation?
    private var referenceGeneration: UInt64 = 0
    private var lastLogTime: ContinuousClock.Instant?
    private let logger = Logger(subsystem: "edu.gatech.contour", category: "TrackingDiagnostics")

    init(processor: any TrackingFrameProcessor = FingertipFrameProcessor()) {
        self.worker = DiagnosticWorker(processor: processor)
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
        lastLogTime = nil
        framesProcessed = 0
        error = nil
        image = nil
        panelQuad = nil
        trackingFrame = nil
        latency = nil
        running = false
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
        log(result)
    }

    func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        await worker.process(frame)
    }

    /// Screen owns only its subscription, never the shared camera lifetime.
    /// Full tracking uses the production emitter's exact same-frame sample.
    func run(camera: CameraService, reference: PanelReference? = nil) async {
        clearDisplayedResults()
        let session = referenceGeneration
        do {
            try await camera.start()
            try Task.checkCancellation()
            guard referenceGeneration == session else { return }
            running = true
            if let reference {
                let pair = AsyncStream<LiveTrackingSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let source = LiveTrackingSource(camera: camera, onSample: { pair.continuation.yield($0) })
                await source.use(reference)
                let drive = Task {
                    for await _ in source.frames() {
                        if Task.isCancelled { break }
                    }
                    pair.continuation.finish()
                }
                await withTaskCancellationHandler {
                    var lastDisplay = Date.distantPast
                    for await sample in pair.stream {
                        guard !Task.isCancelled, referenceGeneration == session else { break }
                        // Production processes every delivered frame; UI draws at most 10 Hz.
                        guard sample.cameraFrame.timestamp.timeIntervalSince(lastDisplay) >= 0.1 else { continue }
                        lastDisplay = sample.cameraFrame.timestamp
                        let rendered = await renderer.image(for: sample.cameraFrame)
                        guard !Task.isCancelled, referenceGeneration == session else { break }
                        image = rendered
                        panelQuad = sample.panelQuad
                        trackingFrame = sample.frame
                        assessment = sample.assessment
                        latency = max(0, Date().timeIntervalSince(sample.cameraFrame.timestamp))
                        latest = TrackingDiagnostics(timestamp: sample.frame.timestamp,
                            fingertip: sample.imageFingertip,
                            status: sample.imageFingertip == nil ? .notDetected : .detected)
                        error = sample.registrationError == nil ? nil
                            : "Panel tracking could not initialize from this reference. Capture again and mark its actual corners."
                        framesProcessed += 1
                    }
                } onCancel: { drive.cancel() }
                drive.cancel()
                await drive.value
            } else {
                var lastDisplay = Date.distantPast
                for await frame in await camera.cameraFrames() {
                    try Task.checkCancellation()
                    guard referenceGeneration == session else { break }
                    guard frame.timestamp.timeIntervalSince(lastDisplay) >= 0.1 else { continue }
                    lastDisplay = frame.timestamp
                    let result = await process(frame)
                    let rendered = await renderer.image(for: frame)
                    try Task.checkCancellation()
                    guard referenceGeneration == session else { break }
                    image = rendered
                    latency = max(0, Date().timeIntervalSince(frame.timestamp))
                    accept(result, from: session)
                }
            }
        } catch is CancellationError {
            // Navigation, backgrounding, or reference replacement.
        } catch {
            if referenceGeneration == session { self.error = error.localizedDescription }
        }
        if referenceGeneration == session {
            running = false
            latest = nil
            image = nil
            panelQuad = nil
            trackingFrame = nil
            assessment = nil
        }
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

#if DEBUG
/// Keeps detector invocations off the UI actor even with caller-isolated async APIs.
private actor DiagnosticWorker {
    let processor: any TrackingFrameProcessor
    init(processor: any TrackingFrameProcessor) { self.processor = processor }
    func process(_ frame: CameraFrame) async -> TrackingDiagnostics { await processor.process(frame) }
}
#endif
