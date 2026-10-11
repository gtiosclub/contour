//
//  ProximityHaptics.swift
//  ContourFeedback — Experience / Haptics
//
//  Weeks 2–3 deliverable: "Prototype proximity haptics."
//
//  How close, as something you feel. This is the channel the user leans on most
//  — it is the only one that works in a loud kitchen with the appliance running.
//
//  Test it by asserting on the PATTERN you would hand to Core Haptics — event
//  times, intensities, sharpness — not on what it feels like. A test that pins
//  "distance 0.8 produces pulses 400 ms apart" catches regressions your fingers
//  will not.
//
//  HOT / COLD
//  Closer is faster, stronger and crisper: one soft pulse every 600 ms at the far
//  edge of the panel, sharp pulses every 70 ms on the button. Anything past the
//  edge of the panel feels like the edge. These numbers are a first pass for the
//  MVP; tune them in the Harness and on a phone.
//

import ContourCore
import Foundation

/// One haptic event, described independently of Core Haptics.
///
/// Keeping the description framework-free is what makes this testable and what
/// lets the Harness log a pattern on a Mac, which has no haptics at all.
public struct HapticEvent: Hashable, Sendable {

    /// Offset from the start of the pattern.
    public var time: Duration

    /// How strong, `0...1`.
    public var intensity: Double

    /// How crisp, `0...1`. Low is a dull thud, high is a tap.
    public var sharpness: Double

    public init(time: Duration, intensity: Double, sharpness: Double) {
        self.time = time
        self.intensity = intensity
        self.sharpness = sharpness
    }
}

/// Turns distance into something the user feels.
public struct ProximityHaptics: Sendable {

    private let player: HapticPlayer

    public init() {
        self.init(player: HapticPlayer())
    }

    /// Shares a player with `OutcomeAnnouncer`, so both use one haptic engine.
    init(player: HapticPlayer) {
        self.player = player
    }

    /// The pattern for a given distance from the target.
    ///
    /// - Parameter normalizedDistance: `0` on target, `1` at the opposite corner
    ///   of the panel. Can exceed `1` when the finger is off the panel.
    /// - Returns: the events to play, earliest first: one second of pulses at
    ///   this distance's rate. Empty for a distance that isn't a number.
    ///
    /// Pure and synchronous on purpose — this is the part you can unit-test.
    public func pattern(forDistance normalizedDistance: Double) -> [HapticEvent] {
        guard let beat = Self.beat(forDistance: normalizedDistance) else { return [] }
        let interval = Self.pulseInterval(forDistance: normalizedDistance)
        var events: [HapticEvent] = []
        var time = Duration.zero
        while time < .seconds(1) {
            events.append(HapticEvent(time: time, intensity: beat.intensity, sharpness: beat.sharpness))
            time += interval
        }
        return events
    }

    /// Play the pattern for `state`.
    ///
    /// Starts the pattern and returns. Does not await playback. Calling this
    /// every frame only changes the rate of the pulses already playing. A state
    /// with no vector stops them.
    public func play(for state: GuidanceState) async {
        guard let distance = state.vector?.normalizedDistance else {
            await player.stopPulsing()
            return
        }
        await player.pulse(forDistance: distance)
    }

    /// Stop anything currently playing. Must be safe to call when idle.
    public func stop() async {
        await player.stopPulsing()
    }

    // MARK: The mapping

    /// Time between pulses: 600 ms at the edge of the panel, 70 ms on target.
    static func pulseInterval(forDistance distance: Double) -> Duration {
        .milliseconds(Int((70 + 530 * clampedDistance(distance)).rounded()))
    }

    /// One pulse at this distance, or `nil` when the distance isn't a number.
    static func beat(forDistance distance: Double) -> HapticEvent? {
        guard !distance.isNaN else { return nil }
        let closeness = 1 - clampedDistance(distance)
        return HapticEvent(
            time: .zero,
            intensity: 0.35 + 0.65 * closeness,
            sharpness: 0.3 + 0.6 * closeness
        )
    }

    /// `0...1`, so a finger off the panel feels like the edge of it.
    private static func clampedDistance(_ distance: Double) -> Double {
        distance.isNaN ? 1 : min(max(distance, 0), 1)
    }
}
