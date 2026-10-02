// Tracking — Fingertip & Frame Math
import ContourCore
import Foundation
import Vision

/// One frame's index fingertip in the full oriented image, not panel space.
/// A missing fingertip never carries forward a position from an earlier frame.
public struct FingertipObservation: Sendable {
    public let timestamp: Date
    public let fingertip: ImagePoint?
    public let confidence: Double?
}

/// Vision's normalized, lower-left-origin index joint before validation.
struct FingertipJoint: Sendable {
    let x: Double
    let y: Double
    let confidence: Double
}

/// Detects one hand's index fingertip without owning a camera or requiring a panel.
/// The integrated pipeline can pass the same CameraFrame to this and its panel detector.
public struct FingertipTracker: Sendable {
    private let detectJoint: @Sendable (CameraFrame) async throws -> FingertipJoint?

    public init() {
        detectJoint = Self.visionJoint
    }

    // Keep the Vision boundary replaceable for deterministic recorded-result tests.
    init(detectJoint: @escaping @Sendable (CameraFrame) async throws -> FingertipJoint?) {
        self.detectJoint = detectJoint
    }

    /// Preserves capture time. Vision errors propagate; an absent or unusable joint
    /// returns an observation with nil position and confidence.
    public func detect(in frame: CameraFrame) async throws -> FingertipObservation {
        try Task.checkCancellation()
        let joint = try await detectJoint(frame)
        try Task.checkCancellation()
        guard let joint,
              joint.confidence.isFinite, joint.confidence > 0.3, joint.confidence <= 1,
              joint.x.isFinite, joint.y.isFinite,
              (0...1).contains(joint.x), (0...1).contains(joint.y) else {
            return FingertipObservation(timestamp: frame.timestamp, fingertip: nil, confidence: nil)
        }
        return FingertipObservation(timestamp: frame.timestamp,
                                   fingertip: ImagePoint(x: joint.x, y: 1 - joint.y),
                                   confidence: joint.confidence)
    }

    private static func visionJoint(in frame: CameraFrame) async throws -> FingertipJoint? {
        // A request belongs to this invocation, so concurrent callers never share
        // mutable Vision state. Pixels remain read-only throughout processing.
        var request = DetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let hands = try await request.perform(on: frame.pixelBuffer, orientation: frame.orientation)
        guard let tip = hands.first?.allJoints(in: .indexFinger)[.indexTip] else { return nil }
        return FingertipJoint(x: Double(tip.location.x), y: Double(tip.location.y),
                              confidence: Double(tip.confidence))
    }
}
