import ContourCore
import Foundation

/// Guidance-side arrival authority, shared by the pipeline and simulated input.
/// The renderer displays onTarget, but never starts an arrival timer itself.
public struct GuidanceArrivalHold: Sendable {
    public static let duration: Duration = .milliseconds(1250)
    /// A camera gap breaks continuity; recovery must establish a new hold.
    public static let maximumSampleGap: Duration = .milliseconds(250)
    private var began: ContinuousClock.Instant?
    private var previous: ContinuousClock.Instant?
    private var completed = false

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func update(_ input: GuidanceState, at now: ContinuousClock.Instant) -> GuidanceState {
        guard let vector = input.vector, vector.normalizedDistance == 0,
              vector.direction.dx.isFinite, vector.direction.dy.isFinite,
              input.outcome == nil || input.outcome == .arrived else {
            reset()
            return input
        }
        if let previous, now <= previous || previous.duration(to: now) >= Self.maximumSampleGap {
            reset()
        }
        previous = now
        if began == nil { began = now }
        if let began, began.duration(to: now) >= Self.duration { completed = true }
        return GuidanceState(timestamp: input.timestamp, vector: .onTarget,
                             outcome: completed ? .arrived : nil)
    }
}
