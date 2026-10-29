import Foundation

/// One loss episode per guidance loop. Only the announcement is delayed;
/// unusable frames quiet feedback immediately. No timer outlives the loop.
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
