#if DEBUG
import CoreGraphics
import ContourCore
import Foundation
import Observation
import OSLog
import Tracking

struct DisplayedTrackingFrame {
    let image: CGImage
    let sample: LiveTrackingSample?
    let diagnostics: TrackingDiagnostics
    let standaloneTrackingFrame: TrackingFrame?
    let standaloneAssessment: TrackingAssessment?
    let latency: TimeInterval

    var panelQuad: PanelQuad? {
        sample?.panelQuad
    }

    var trackingFrame: TrackingFrame? {
        sample?.frame ?? standaloneTrackingFrame
    }

    var assessment: TrackingAssessment? {
        sample?.assessment ?? standaloneAssessment
    }
}

@MainActor
@Observable
final class TrackingDebugModel {
    private(set) var latest: TrackingDiagnostics?
    private(set) var assessment: TrackingAssessment?
    private(set) var framesProcessed = 0
    private(set) var error: String?
    private(set) var running = false

    private(set) var displayedFrame: DisplayedTrackingFrame?
    private(set) var acceptedFeaturePoints: [ImagePoint] = []

    var image: CGImage? { displayedFrame?.image }
    var panelQuad: PanelQuad? { displayedFrame?.panelQuad }
    var trackingFrame: TrackingFrame? { displayedFrame?.trackingFrame }
    var latency: TimeInterval? { displayedFrame?.latency }

    private let sessionFactory: GuidanceSessionFactory
    private let worker: DiagnosticWorker
    private let renderImage: @MainActor (CameraFrame) async -> CGImage?
    private let displayNow: @MainActor () -> ContinuousClock.Instant
    private let evaluator: TrackingQualityEvaluator
    private var previous: TrackingObservation?
    private var referenceGeneration: UInt64 = 0
    private var lastLogTime: ContinuousClock.Instant?
    private let logger = Logger(
        subsystem: "edu.gatech.contour",
        category: "TrackingDiagnostics"
    )

    init(processor: any TrackingFrameProcessor = FingertipFrameProcessor(),
         sessionFactory: @escaping GuidanceSessionFactory = GuidanceSessionFactories.vision,
         renderImage: (@MainActor (CameraFrame) async -> CGImage?)? = nil,
         displayNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.sessionFactory = sessionFactory
        self.worker = DiagnosticWorker(processor: processor)
        let renderer = FrameImageRenderer()
        self.renderImage = renderImage ?? { await renderer.image(for: $0) }
        self.displayNow = displayNow
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
        displayedFrame = nil
        acceptedFeaturePoints = []
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

    func visualFingertip(in frame: CameraFrame, panelTracked: Bool,
                        fingertip: ImagePoint?) async -> TrackingDiagnostics {
        // Fusion deliberately skips finger detection without a usable panel.
        // Diagnostics can still observe the raw image-space finger, without
        // making a panel-space position or guidance claim.
        guard panelTracked else { return await process(frame) }
        return TrackingDiagnostics(timestamp: frame.timestamp, fingertip: fingertip,
                                   status: fingertip == nil ? .notDetected : .detected)
    }

    /// Screen owns only its subscription, never the shared camera lifetime.
    /// Full tracking uses the production emitter's exact same-frame sample.
    func run(camera: any CameraControl, reference: PanelReference? = nil,
             method: PanelTrackingMethod = .vision,
             options: FeatureTrackingOptions = FeatureTrackingOptions()) async {
        clearDisplayedResults()
        let session = referenceGeneration
        do {
            try await camera.start()
            try Task.checkCancellation()
            guard referenceGeneration == session else { return }
            running = true
            if let reference {
                let pair = AsyncStream<LiveTrackingSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let source = try sessionFactory(camera, method, options, { pair.continuation.yield($0) })
                await source.use(reference)
                guard !Task.isCancelled, referenceGeneration == session else { return }
                let drive = Task {
                    for await _ in source.frames() {
                        if Task.isCancelled { break }
                    }
                    pair.continuation.finish()
                }
                await withTaskCancellationHandler {
                    var lastDisplay: ContinuousClock.Instant?
                    for await sample in pair.stream {
                        guard !Task.isCancelled, referenceGeneration == session else { break }
                        // Production processes every delivered frame; UI draws at most 10 Hz.
                        guard lastDisplay.map({ $0.duration(to: displayNow()) >= .milliseconds(100) }) ?? true else { continue }
                        let finger = await visualFingertip(
                            in: sample.cameraFrame,
                            panelTracked: sample.panelQuad != nil,
                            fingertip: sample.imageFingertip
                        )

                        guard let rendered = await renderImage(sample.cameraFrame) else {
                            continue
                        }

                        guard !Task.isCancelled,
                              referenceGeneration == session else {
                            break
                        }

                        let display = DisplayedTrackingFrame(
                            image: rendered,
                            sample: sample,
                            diagnostics: finger,
                            standaloneTrackingFrame: nil,
                            standaloneAssessment: nil,
                            latency: max(
                                0,
                                Date().timeIntervalSince(sample.cameraFrame.timestamp)
                            )
                        )

                        displayedFrame = display
                        lastDisplay = displayNow()
                        acceptedFeaturePoints = sample.featureDiagnostics?.inlierPoints ?? []
                        latest = finger
                        assessment = sample.assessment
                        error = sample.registrationError == nil ? nil
                            : "Panel tracking could not initialize from this reference. Capture again and mark its actual corners."
                        framesProcessed += 1
                    }
                } onCancel: { drive.cancel() }
                drive.cancel()
                await drive.value
            } else {
                var lastDisplay: ContinuousClock.Instant?
                for await frame in await camera.cameraFrames() {
                    try Task.checkCancellation()
                    guard referenceGeneration == session else { break }
                    guard lastDisplay.map({ $0.duration(to: displayNow()) >= .milliseconds(100) }) ?? true else { continue }
                    let result = await process(frame)
                    guard let rendered = await renderImage(frame) else {
                        continue
                    }

                    try Task.checkCancellation()
                    guard referenceGeneration == session else { break }

                    accept(result, from: session)

                    displayedFrame = DisplayedTrackingFrame(
                        image: rendered,
                        sample: nil,
                        diagnostics: result,
                        standaloneTrackingFrame: nil,
                        standaloneAssessment: assessment,
                        latency: max(
                            0,
                            Date().timeIntervalSince(frame.timestamp)
                        )
                    )
                    lastDisplay = displayNow()
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
            displayedFrame = nil
            acceptedFeaturePoints = []
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
