//
//  VibrationTests.swift
//  ContourFeedbackTests — Experience / Haptics
//
//  Pins the patterns, not the feel: pulse spacing and strength by distance,
//  and the four outcome signatures. On a Mac there is no haptic hardware, so
//  playing anything here is a safe no-op.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

private func state(distance: Double?) -> GuidanceState {
    GuidanceState(
        timestamp: Date(timeIntervalSince1970: 0),
        vector: distance.map { GuidanceVector(direction: PanelVector(dx: 0, dy: 1), normalizedDistance: $0) }
    )
}

@Test("closer is faster and stronger")
func closerIsFasterAndStronger() throws {
    let haptics = ProximityHaptics()
    let far = haptics.pattern(forDistance: 1)
    let near = haptics.pattern(forDistance: 0.1)

    #expect(near.count > far.count)
    let farFirst = try #require(far.first), nearFirst = try #require(near.first)
    #expect(nearFirst.intensity > farFirst.intensity)
    #expect(nearFirst.sharpness > farFirst.sharpness)
}

@Test("distance 0.8 pulses every 494 ms")
func pulseSpacingAtPointEight() {
    let times = ProximityHaptics().pattern(forDistance: 0.8).map(\.time)
    #expect(times == [.zero, .milliseconds(494), .milliseconds(988)])
}

@Test("the edge of the panel pulses every 600 ms, the button every 70 ms")
func pulseSpacingAtTheEnds() {
    #expect(ProximityHaptics.pulseInterval(forDistance: 1) == .milliseconds(600))
    #expect(ProximityHaptics.pulseInterval(forDistance: 0) == .milliseconds(70))
}

@Test("a pattern is one second of pulses, earliest first")
func patternIsOneSecondInOrder() {
    for distance in [0, 0.25, 0.5, 0.75, 1] {
        let times = ProximityHaptics().pattern(forDistance: distance).map(\.time)
        #expect(times == times.sorted())
        #expect(times.allSatisfy { $0 >= .zero && $0 < .seconds(1) })
        #expect(times.first == .zero)
    }
}

@Test("off the panel feels like the edge of it")
func offPanelFeelsLikeTheEdge() {
    let haptics = ProximityHaptics()
    #expect(haptics.pattern(forDistance: 2.5) == haptics.pattern(forDistance: 1))
    #expect(haptics.pattern(forDistance: -0.2) == haptics.pattern(forDistance: 0))
}

@Test("a distance that isn't a number plays nothing")
func nanPlaysNothing() {
    #expect(ProximityHaptics().pattern(forDistance: .nan).isEmpty)
}

@Test("every outcome has its own haptic signature")
func outcomesAreDistinct() {
    let announcer = OutcomeAnnouncer()
    let signatures = OutcomeSignal.allCases.map { announcer.presentation(for: $0).haptics }
    #expect(Set(signatures).count == OutcomeSignal.allCases.count)
    #expect(signatures.allSatisfy { !$0.isEmpty })
}

@Test("notFound and lowConfidence don't feel the same")
func notFoundIsNotLowConfidence() {
    let announcer = OutcomeAnnouncer()
    let notFound = announcer.presentation(for: .notFound).haptics
    let unsure = announcer.presentation(for: .lowConfidence).haptics
    #expect(notFound.count != unsure.count)
    #expect(notFound.map(\.sharpness) != unsure.map(\.sharpness))
}

@Test("arrived interrupts the pulses")
func arrivedInterrupts() {
    #expect(OutcomeAnnouncer().presentation(for: .arrived).interrupts)
}

@MainActor
@Test("pulses start with a vector, stop without one, and stop for an outcome")
func pulsingFollowsTheState() async {
    let player = HapticPlayer()
    let proximity = ProximityHaptics(player: player)
    let announcer = OutcomeAnnouncer(player: player)

    await proximity.play(for: state(distance: 0.5))
    #expect(player.isPulsing)

    await proximity.play(for: state(distance: nil))
    #expect(!player.isPulsing)

    await proximity.play(for: state(distance: 0.2))
    await announcer.announce(.arrived)
    #expect(!player.isPulsing)
}

@Test("present returns right away and never traps, for every kind of state")
func presentReturnsPromptly() async {
    let engine = LiveFeedbackEngine()
    let states = [state(distance: 1), state(distance: 0.4), state(distance: 0), state(distance: nil)]
        + OutcomeSignal.allCases.map { GuidanceState.outcome($0, at: Date(timeIntervalSince1970: 0)) }

    let clock = ContinuousClock()
    for subject in states {
        let elapsed = await clock.measure { await engine.present(subject) }
        #expect(elapsed < .milliseconds(50), "present took \(elapsed) for \(subject)")
    }
}
