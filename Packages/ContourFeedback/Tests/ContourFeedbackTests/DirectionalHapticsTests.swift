//
//  DirectionalHapticsTests.swift
//  ContourFeedbackTests — Experience / Haptics
//
//  Pins the direction cue prototype (#119): which way each vector points, the
//  four cue patterns, and when a cue fires. Timing runs off the states'
//  timestamps, so none of this waits on a clock.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

private let start = Date(timeIntervalSince1970: 0)

private func state(
    _ direction: PanelVector?,
    distance: Double = 0.5,
    at seconds: TimeInterval = 0
) -> GuidanceState {
    GuidanceState(
        timestamp: start.addingTimeInterval(seconds),
        vector: direction.map { GuidanceVector(direction: $0, normalizedDistance: distance) }
    )
}

private let up = PanelVector(dx: 0, dy: -1)
private let down = PanelVector(dx: 0, dy: 1)
private let left = PanelVector(dx: -1, dy: 0)
private let right = PanelVector(dx: 1, dy: 0)

// MARK: Which way

@Test("+dy is down: a target above the finger cues up")
func targetAboveCuesUp() {
    let finger = PanelPoint(x: 0.5, y: 0.8)
    let target = PanelPoint(x: 0.5, y: 0.2)
    #expect(HapticDirection(finger.vector(to: target)) == .up)
    #expect(HapticDirection(target.vector(to: finger)) == .down)
}

@Test("each axis maps to its direction")
func cardinalDirections() {
    #expect(HapticDirection(up) == .up)
    #expect(HapticDirection(down) == .down)
    #expect(HapticDirection(left) == .left)
    #expect(HapticDirection(right) == .right)
}

@Test("a diagonal snaps to its larger axis, and a tie goes to up/down")
func diagonalsSnap() {
    #expect(HapticDirection(PanelVector(dx: 0.9, dy: -0.3)) == .right)
    #expect(HapticDirection(PanelVector(dx: -0.2, dy: 0.7)) == .down)
    #expect(HapticDirection(PanelVector(dx: 0.5, dy: -0.5)) == .up)
}

@Test("no direction for a zero or broken vector")
func noDirection() {
    #expect(HapticDirection(.zero) == nil)
    #expect(HapticDirection(PanelVector(dx: .nan, dy: 1)) == nil)
    #expect(HapticDirection(PanelVector(dx: 1, dy: .infinity)) == nil)
}

// MARK: How each cue feels

@Test("the four cues are distinct from each other and from every outcome")
func cuesAreDistinct() {
    let cues = HapticDirection.allCases.map(DirectionalHaptics.pattern(for:))
    #expect(Set(cues).count == HapticDirection.allCases.count)
    #expect(cues.allSatisfy { !$0.isEmpty })

    let announcer = OutcomeAnnouncer()
    let outcomes = Set(OutcomeSignal.allCases.map { announcer.presentation(for: $0).haptics })
    #expect(outcomes.isDisjoint(with: cues))
}

@Test("crisp is up/down, dull is left/right")
func textureIsTheAxis() {
    for vertical in [HapticDirection.up, .down] {
        for horizontal in [HapticDirection.left, .right] {
            let crisp = DirectionalHaptics.pattern(for: vertical).map(\.sharpness)
            let dull = DirectionalHaptics.pattern(for: horizontal).map(\.sharpness)
            #expect(zip(crisp, dull).allSatisfy { $0 > $1 })
        }
    }
}

@Test("rising is up or right, falling is down or left")
func orderIsTheWay() {
    func isRising(_ direction: HapticDirection) -> Bool {
        let intensities = DirectionalHaptics.pattern(for: direction).map(\.intensity)
        return intensities.first! < intensities.last!
    }
    #expect(isRising(.up))
    #expect(isRising(.right))
    #expect(!isRising(.down))
    #expect(!isRising(.left))
}

@Test("a cue is two taps, 120 ms apart")
func cueTiming() {
    for direction in HapticDirection.allCases {
        let times = DirectionalHaptics.pattern(for: direction).map(\.time)
        #expect(times == [.zero, .milliseconds(120)])
    }
}

// MARK: When a cue fires

@Test("the first frame with a direction cues it")
func firstFrameCues() {
    var schedule = DirectionalCueSchedule()
    #expect(schedule.cue(for: state(up)) == .up)
}

@Test("the same direction waits 1.5 s before repeating")
func sameDirectionRepeatsSlowly() {
    var schedule = DirectionalCueSchedule()
    #expect(schedule.cue(for: state(left, at: 0)) == .left)
    #expect(schedule.cue(for: state(left, at: 0.5)) == nil)
    #expect(schedule.cue(for: state(left, at: 1.4)) == nil)
    #expect(schedule.cue(for: state(left, at: 1.5)) == .left)
}

@Test("a new direction cues after 0.5 s, not sooner")
func newDirectionCuesSooner() {
    var schedule = DirectionalCueSchedule()
    #expect(schedule.cue(for: state(left, at: 0)) == .left)
    #expect(schedule.cue(for: state(down, at: 0.2)) == nil)
    #expect(schedule.cue(for: state(down, at: 0.5)) == .down)
}

@Test("close to the button, hot/cold does the work alone")
func noCuesUpClose() {
    var schedule = DirectionalCueSchedule()
    #expect(schedule.cue(for: state(up, distance: 0.05)) == nil)
    #expect(schedule.cue(for: state(up, distance: DirectionalCueSchedule.closeRange)) == .up)
}

@Test("no cue without a vector or with an outcome, and a reset starts fresh")
func nothingToCue() {
    var schedule = DirectionalCueSchedule()
    #expect(schedule.cue(for: state(nil)) == nil)
    #expect(schedule.cue(for: .outcome(.arrived, at: start)) == nil)

    #expect(schedule.cue(for: state(right, at: 0)) == .right)
    schedule.reset()
    #expect(schedule.cue(for: state(right, at: 0.1)) == .right)
}

// MARK: The flag

@MainActor
@Test("cues play only with the flag on")
func flagGatesCues() async {
    let off = HapticPlayer()
    await LiveFeedbackEngine(player: off) { false }.present(state(up))
    #expect(!off.isPlayingSignal)
    #expect(off.isPulsing, "hot/cold still runs with the flag off")

    let on = HapticPlayer()
    await LiveFeedbackEngine(player: on) { true }.present(state(up))
    #expect(on.isPlayingSignal)
    #expect(on.isPulsing)
}

@MainActor
@Test("a cue never cuts off an outcome signal, and isn't used up by trying")
func cueWaitsForOutcome() {
    let player = HapticPlayer()
    let directions = DirectionalHaptics(player: player)
    player.play(OutcomeAnnouncer().presentation(for: .lostTracking).haptics)
    #expect(player.isPlayingSignal)

    directions.play(for: state(up))
    #expect(directions.schedule.last == nil, "a skipped cue must not count as played")
}
