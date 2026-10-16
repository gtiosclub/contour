import Foundation
import OSLog

/// Adapts the reusable image-space detector to the app's existing debug interface.
public struct FingertipFrameProcessor: TrackingFrameProcessor {
    private let tracker: FingertipTracker
    private static let logger = Logger(subsystem: "edu.gatech.contour", category: "FingertipDetection")

    public init(tracker: FingertipTracker = FingertipTracker()) {
        self.tracker = tracker
    }

    public func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        do {
            let observation = try await tracker.detect(in: frame)
            return TrackingDiagnostics(timestamp: observation.timestamp,
                                       fingertip: observation.fingertip,
                                       confidence: observation.confidence,
                                       status: observation.fingertip == nil ? .notDetected : .detected)
        } catch is CancellationError {
            // The consuming lifecycle task handles cancellation and camera cleanup.
        } catch {
            Self.logger.debug("Fingertip detection failed: \(String(describing: error), privacy: .public)")
        }
        return TrackingDiagnostics(timestamp: frame.timestamp, status: .notDetected)
    }
}
