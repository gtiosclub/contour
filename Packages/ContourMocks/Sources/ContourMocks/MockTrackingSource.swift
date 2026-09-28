import ContourCore
import Foundation

/// A deterministic script for a mock tracking run.
public struct MockRun: Sendable {
    public enum Motion: Sendable, Equatable {
        case straight
        case overshoot
    }

    public let start: PanelPoint
    public let targetButtonID: UUID
    public let duration: TimeInterval
    public let dropoutWindow: Range<TimeInterval>?
    public let motion: Motion

    public init(
        start: PanelPoint,
        targetButtonID: UUID,
        duration: TimeInterval,
        dropoutWindow: Range<TimeInterval>? = nil,
        motion: Motion = .straight
    ) {
        precondition(duration > 0, "MockRun duration must be positive")
        self.start = start
        self.targetButtonID = targetButtonID
        self.duration = duration
        self.dropoutWindow = dropoutWindow
        self.motion = motion
    }

    public static let straight = MockRun(
        start: PanelPoint(x: 0.12, y: 0.14),
        targetButtonID: MockSurfaceMap.microwaveStartButton.id,
        duration: 2
    )

    public static let overshoot = MockRun(
        start: PanelPoint(x: 0.12, y: 0.14),
        targetButtonID: MockSurfaceMap.microwaveStartButton.id,
        duration: 2,
        motion: .overshoot
    )

    public static let withDropout = MockRun(
        start: PanelPoint(x: 0.12, y: 0.14),
        targetButtonID: MockSurfaceMap.microwaveStartButton.id,
        duration: 2,
        dropoutWindow: 0.75..<1.25
    )
}

/// A 30 Hz TrackingSource driven by a deterministic MockRun.
public struct MockTrackingSource: TrackingSource {
    public static let framesPerSecond = 30
    public static let fixedEpoch = Date(timeIntervalSince1970: 1_767_225_600)

    public let run: MockRun
    public let map: SurfaceMap
    public let baseTimestamp: Date

    public init(
        run: MockRun = .straight,
        map: SurfaceMap = MockSurfaceMap.microwave,
        baseTimestamp: Date = MockTrackingSource.fixedEpoch
    ) {
        precondition(map.buttons.contains(where: { $0.id == run.targetButtonID }),
                     "MockRun targetButtonID must exist in the supplied map")
        self.run = run
        self.map = map
        self.baseTimestamp = baseTimestamp
    }

    public var target: PanelPoint {
        map.buttons.first(where: { $0.id == run.targetButtonID })!.bounds.center
    }

    /// Number of travel ticks; the source then holds on the target for two seconds.
    public var steps: Int {
        max(1, Int((run.duration * Double(Self.framesPerSecond)).rounded()))
    }

    public var totalSteps: Int {
        steps + 2 * Self.framesPerSecond
    }

    /// The deterministic frame at a tick. Also useful for scrubbing in debug UI.
    public func frame(atStep step: Int) -> TrackingFrame {
        let tick = min(max(step, 0), totalSteps)
        let elapsed = Double(tick) / Double(Self.framesPerSecond)
        let timestamp = baseTimestamp.addingTimeInterval(elapsed)

        guard !(run.dropoutWindow?.contains(elapsed) ?? false) else {
            return .lost(at: timestamp)
        }

        return TrackingFrame(
            timestamp: timestamp,
            fingertip: point(at: tick),
            panel: Self.pose,
            trackingQuality: .good
        )
    }

    public func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                var deadline = clock.now

                for tick in 0...totalSteps {
                    if Task.isCancelled { break }
                    continuation.yield(frame(atStep: tick))

                    guard tick < totalSteps else { continue }
                    deadline = deadline.advanced(by: .seconds(1) / Self.framesPerSecond)
                    do {
                        try await clock.sleep(until: deadline)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func point(at tick: Int) -> PanelPoint {
        guard tick < steps else { return target }

        let progress = Double(tick) / Double(steps)
        let displacement = run.start.vector(to: target)
        let distance = displacement.magnitude
        let travel: Double
        if run.motion == .overshoot, distance > 0 {
            // Reach exactly 0.1 panel units past the target, then return to it.
            let overshootDistance = 0.1 / distance
            if progress < 0.8 {
                let phase = progress / 0.8
                let eased = phase * phase * (3 - 2 * phase)
                travel = eased * (1 + overshootDistance)
            } else {
                let phase = (progress - 0.8) / 0.2
                let eased = phase * phase * (3 - 2 * phase)
                travel = 1 + overshootDistance * (1 - eased)
            }
        } else {
            travel = progress * progress * (3 - 2 * progress)
        }

        let base = PanelPoint(
            x: run.start.x + displacement.dx * travel,
            y: run.start.y + displacement.dy * travel
        )
        let perpendicular = PanelVector(dx: -displacement.dy, dy: displacement.dx).normalized ?? .zero
        let wobble = 0.01 * sin(4 * .pi * progress)
        return base.offset(by: PanelVector(
            dx: perpendicular.dx * wobble,
            dy: perpendicular.dy * wobble
        ))
    }

    private static let pose = PanelPose(
        column0: SIMD4(1, 0, 0, 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0),
        column3: SIMD4(0, 0, -0.4, 1),
        confidence: 0.92
    )
}
