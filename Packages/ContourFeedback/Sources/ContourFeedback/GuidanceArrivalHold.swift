import ContourCore
import Foundation

/// Guidance-side arrival authority, shared by the pipeline and simulated input.
/// The renderer displays onTarget, but never starts an arrival timer itself.
public struct GuidanceArrivalHold: Sendable {
    public static let duration: Duration = .milliseconds(1250)
    /// How long a pending hold lasts without a frame that sees the finger on the
    /// target: frames where hand pose missed the fingertip, or no frames at all
    /// while the phone is busy. A phone running ARKit, hand pose and panel tracking
    /// at once does both, and starting over on every miss could stop arrival ever
    /// firing. Any longer and the hold starts over.
    public static let maximumDropout: Duration = .milliseconds(500)
    private var began: ContinuousClock.Instant?
    /// The last frame that saw the finger on the target.
    private var seen: ContinuousClock.Instant?
    private var previous: ContinuousClock.Instant?
    private var completed = false

    public init() {}

    public mutating func reset() { self = Self() }

    /// Only a frame that sees the finger on the target can complete the hold, and
    /// seeing it anywhere else, or losing the panel, starts the hold over. A frame
    /// that missed the fingertip keeps a pending hold, and what it plays, going.
    public mutating func update(_ input: GuidanceState, at now: ContinuousClock.Instant) -> GuidanceState {
        if let previous, now <= previous { reset() }
        if let seen, seen.duration(to: now) >= Self.maximumDropout { reset() }
        previous = now
        if input.vector == nil, input.outcome == nil {
            guard began != nil else { return input }
            return GuidanceState(timestamp: input.timestamp, vector: .onTarget,
                                 outcome: completed ? .arrived : nil)
        }
        guard let vector = input.vector, vector.normalizedDistance == 0,
              vector.direction.dx.isFinite, vector.direction.dy.isFinite,
              input.outcome == nil || input.outcome == .arrived else {
            reset()
            return input
        }
        if began == nil { began = now }
        seen = now
        if let began, began.duration(to: now) >= Self.duration { completed = true }
        return GuidanceState(timestamp: input.timestamp, vector: .onTarget,
                             outcome: completed ? .arrived : nil)
    }
}
