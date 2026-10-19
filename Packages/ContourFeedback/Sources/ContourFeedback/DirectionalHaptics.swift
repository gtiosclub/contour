//
//  DirectionalHaptics.swift
//  ContourFeedback — Experience / Haptics
//
//  Prototype for #119: which way to move, as something you feel.
//
//  Without headphones, or in a loud kitchen, hot/cold pulses say how close the
//  finger is but nothing says which way to go. This adds `discreteDirectional`
//  from GuidanceModelKind on top of hot/cold: every so often, a short two-tap
//  cue for up, down, left or right. It is off unless the flag is on (see
//  LiveFeedbackEngine.directionalHintsKey), so the bake-off can compare it
//  against hot/cold alone.
//
//  THE CUES
//  Texture says the axis, the order says which way:
//    - crisp taps are up/down, dull taps are left/right
//    - soft-then-strong ("rising") is up or right,
//      strong-then-soft ("falling") is down or left
//  Every number here is a first pass. Tune it blindfolded.
//
//  COORDINATES
//  `direction` is panel space: +dx is right, +dy is DOWN. A target above the
//  finger has negative dy and must produce `.up`.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// One of the four ways a cue can point.
enum HapticDirection: Hashable, Sendable, CaseIterable {
    case up, down, left, right

    /// The dominant way to move, or `nil` when there is no way to tell.
    ///
    /// Snaps to whichever axis is larger; a tie goes to up/down.
    init?(_ vector: PanelVector) {
        guard vector.dx.isFinite, vector.dy.isFinite, vector != .zero else { return nil }
        if abs(vector.dx) > abs(vector.dy) {
            self = vector.dx > 0 ? .right : .left
        } else {
            // +dy is DOWN in panel space.
            self = vector.dy > 0 ? .down : .up
        }
    }
}

/// When to cue, decided from the states' timestamps so it is testable.
///
/// Direction is chatty at close range and annoying when repeated, so a cue
/// fires only when the finger is not already close, and then only on a change
/// of direction or after a pause in the same one.
struct DirectionalCueSchedule: Sendable {

    /// Closer than this, hot/cold alone does the work.
    static let closeRange = 0.08

    /// The same direction repeats no sooner than this.
    static let repeatInterval: TimeInterval = 1.5

    /// A new direction still waits this long after the last cue, so a finger
    /// on a diagonal doesn't flip-flop between two cues.
    static let changeInterval: TimeInterval = 0.5

    private(set) var last: (direction: HapticDirection, time: Date)?

    /// The direction to cue for `state` now, or `nil` for none. Records the
    /// cue it returns.
    mutating func cue(for state: GuidanceState) -> HapticDirection? {
        guard state.outcome == nil,
              let vector = state.vector,
              vector.normalizedDistance >= Self.closeRange,
              let direction = HapticDirection(vector.direction) else { return nil }

        if let last {
            let elapsed = state.timestamp.timeIntervalSince(last.time)
            let wait = direction == last.direction ? Self.repeatInterval : Self.changeInterval
            guard elapsed >= wait else { return nil }
        }
        last = (direction, state.timestamp)
        return direction
    }

    /// Forget the last cue, so the next approach starts with one.
    mutating func reset() {
        last = nil
    }
}

/// Plays a direction cue now and then, on top of the proximity pulses.
@MainActor
final class DirectionalHaptics {

    private let player: HapticPlayer
    /// Readable for tests.
    private(set) var schedule = DirectionalCueSchedule()

    nonisolated init(player: HapticPlayer) {
        self.player = player
    }

    /// Cue the way to move for `state`, if it's time to. Starts and returns.
    ///
    /// Never cuts off something already playing: an outcome signal or the
    /// previous cue finishes first.
    func play(for state: GuidanceState) {
        guard state.vector != nil else { return schedule.reset() }
        guard !player.isPlayingSignal, let direction = schedule.cue(for: state) else { return }
        player.play(Self.pattern(for: direction))
    }

    /// Start the next approach fresh.
    func reset() {
        schedule.reset()
    }

    // MARK: The cues

    /// Time between the two taps of a cue.
    nonisolated static let tapGap: Duration = .milliseconds(120)

    /// The two taps for `direction`. See the header for the scheme.
    nonisolated static func pattern(for direction: HapticDirection) -> [HapticEvent] {
        let sharpness: Double
        switch direction {
        case .up, .down: sharpness = 0.9
        case .left, .right: sharpness = 0.15
        }
        let rising = direction == .up || direction == .right
        let intensities = rising ? [0.45, 1.0] : [1.0, 0.45]
        return intensities.enumerated().map { index, intensity in
            HapticEvent(time: tapGap * index, intensity: intensity, sharpness: sharpness)
        }
    }
}
