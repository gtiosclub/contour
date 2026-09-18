import Foundation
import ContourCore

/// Debug output only. Never substitute this for a panel-space TrackingFrame.
public struct TrackingDiagnostics: Sendable {
    public enum Status: String, Sendable {
        case unimplemented = "Detector not implemented"
        case detected = "Fingertip detected"
        case notDetected = "No fingertip detected"
    }
    public var timestamp: Date
    public var fingertip: ImagePoint?
    public var confidence: Double?
    public var status: Status

    public init(timestamp: Date, fingertip: ImagePoint? = nil,
                confidence: Double? = nil, status: Status) {
        self.timestamp = timestamp
        self.fingertip = fingertip
        self.confidence = confidence
        self.status = status
    }
}

public protocol TrackingFrameProcessor: Sendable {
    func process(_ frame: CameraFrame) async -> TrackingDiagnostics
}

/// Wiring placeholder: receives actual frames but makes no detection claims.
/// Tracking: replace the injected processor with your Vision implementation.
public struct UnimplementedFrameProcessor: TrackingFrameProcessor {
    public init() {}
    public func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        TrackingDiagnostics(timestamp: frame.timestamp, status: .unimplemented)
    }
}
