import ContourCore
import Foundation

/// The shared, pure guidance calculation used by mocks and the Harness.
public enum GuidanceMath {
    private static let panelDiagonal = 2.0.squareRoot()

    /// Computes guidance from a tracking frame to a button's center.
    public static func compute(
        frame: TrackingFrame,
        target: SurfaceMap.Button
    ) -> GuidanceState {
        guard frame.trackingQuality != .lost, let fingertip = frame.fingertip else {
            return .outcome(.lostTracking, at: frame.timestamp)
        }

        let vector = fingertip.vector(to: target.bounds.center)
        let length = vector.magnitude
        let distance = min(max(length / panelDiagonal, 0), 1)

        return GuidanceState(
            timestamp: frame.timestamp,
            vector: GuidanceVector(
                direction: vector.normalized ?? .zero,
                normalizedDistance: distance
            ),
            outcome: length == 0 ? .arrived : nil
        )
    }
}

/// Chains a MockTrackingSource through GuidanceMath at 30 Hz.
public struct MockGuidanceSource: Sendable {
    public let tracking: MockTrackingSource
    public let target: SurfaceMap.Button

    public init(tracking: MockTrackingSource, target: SurfaceMap.Button) {
        self.tracking = tracking
        self.target = target
    }

    public init(run: MockRun = .straight, map: SurfaceMap = MockSurfaceMap.microwave) {
        let tracking = MockTrackingSource(run: run, map: map)
        self.init(
            tracking: tracking,
            target: map.buttons.first(where: { $0.id == run.targetButtonID })!
        )
    }

    public func states() -> AsyncStream<GuidanceState> {
        AsyncStream { continuation in
            let task = Task {
                for await frame in tracking.frames() {
                    if Task.isCancelled { break }
                    continuation.yield(GuidanceMath.compute(frame: frame, target: target))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Compatibility wrapper for early callers. New code should use GuidanceMath.
public enum MockGuidance {
    public static func state(for frame: TrackingFrame, target: SurfaceMap.Button) -> GuidanceState {
        GuidanceMath.compute(frame: frame, target: target)
    }
}
