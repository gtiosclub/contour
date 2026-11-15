import ContourUI
import Foundation

/// When to tell a VoiceOver user their finger cannot be seen. Fingertip
/// detection drops in and out, so one stretch without a finger survives brief
/// detections: it ends only once the finger has been seen for `recovery`.
/// It is announced once, after `delay` in total, and only while the finger is
/// missing at that moment.
struct MissingFingerEpisode {
    static let delay: Duration = .seconds(3)
    static let recovery: Duration = .milliseconds(500)

    private var missingSince: ContinuousClock.Instant?
    private var seenSince: ContinuousClock.Instant?
    private var announced = false

    mutating func phaseChanged(to phase: GuidancePhase?, at now: ContinuousClock.Instant) {
        switch phase {
        case .findingFinger:
            if missingSince == nil { missingSince = now }
            seenSince = nil
        case .guiding, .holding:
            if missingSince != nil, seenSince == nil { seenSince = now }
        case .searching:
            // A brief panel gap says nothing about the finger.
            break
        default:
            // Lost tracking is announced on its own; endings and Stop end the episode.
            self = Self()
        }
    }

    /// When `check(at:)` next has something to decide, or `nil` if nothing is pending.
    var nextCheck: ContinuousClock.Instant? {
        if let seenSince { return seenSince.advanced(by: Self.recovery) }
        if let missingSince, !announced { return missingSince.advanced(by: Self.delay) }
        return nil
    }

    /// Returns `true` exactly when the announcement should be made now.
    mutating func check(at now: ContinuousClock.Instant) -> Bool {
        if let seenSince {
            if seenSince.duration(to: now) >= Self.recovery { self = Self() }
            return false
        }
        guard let missingSince, !announced, missingSince.duration(to: now) >= Self.delay else { return false }
        announced = true
        return true
    }
}
