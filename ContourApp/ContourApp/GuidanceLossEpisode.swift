import Foundation

/// Draft #92 policy: owned by one guidance loop, with no detached timer or
/// delayed output. The caller still needs to wire decisions into feedback.
struct GuidanceLossEpisode {
    enum Decision: Equatable {
        case resume
        case quiet
        case announceLoss
    }

    private var began: ContinuousClock.Instant?
    private var announced = false
    private let announcementDelay: Duration = .milliseconds(400)

    mutating func update(isUsable: Bool, at now: ContinuousClock.Instant) -> Decision {
        guard !isUsable else {
            reset()
            return .resume
        }
        guard let began else {
            self.began = now
            return .quiet
        }
        if !announced && began.duration(to: now) >= announcementDelay {
            announced = true
            return .announceLoss
        }
        return .quiet
    }

    mutating func reset() {
        began = nil
        announced = false
    }
}
