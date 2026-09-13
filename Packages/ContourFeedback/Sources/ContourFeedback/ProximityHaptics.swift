//
//  ProximityHaptics.swift
//  ContourFeedback — Team 3
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

    public init() {}

    /// The pattern for a given distance from the target.
    ///
    /// - Parameter normalizedDistance: `0` on target, `1` at the opposite corner
    ///   of the panel. Can exceed `1` when the finger is off the panel.
    /// - Returns: the events to play, earliest first.
    ///
    /// Pure and synchronous on purpose — this is the part you can unit-test.
    public func pattern(forDistance normalizedDistance: Double) -> [HapticEvent] {
        fatalError("unimplemented — owned by Team 3 (ContourFeedback)")
    }

    /// Play the pattern for `state`.
    ///
    /// Starts the pattern and returns. Does not await playback.
    public func play(for state: GuidanceState) async {
        fatalError("unimplemented — owned by Team 3 (ContourFeedback)")
    }

    /// Stop anything currently playing. Must be safe to call when idle.
    public func stop() async {
        fatalError("unimplemented — owned by Team 3 (ContourFeedback)")
    }
}
