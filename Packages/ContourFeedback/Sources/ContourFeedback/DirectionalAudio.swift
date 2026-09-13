//
//  DirectionalAudio.swift
//  ContourFeedback — Team 3
//
//  Weeks 2–3 deliverable: "Prototype directional audio."
//
//  Which way, as something you hear.
//
//  ⚠️ THE AXIS TRAP
//  `direction.dy` is POSITIVE DOWNWARD. A direction of (0, -1) means "move the
//  finger UP the panel". If you map dy straight onto pitch without thinking
//  about it, higher pitch will mean "move down" and every user will go the wrong
//  way — and they cannot see that they are going the wrong way.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A moment of directional audio, described independently of AVFoundation.
///
/// Framework-free so it can be asserted on in tests and logged by the Harness.
public struct AudioCue: Hashable, Sendable {

    /// Stereo position, `-1` hard left to `+1` hard right.
    public var pan: Double

    /// Pitch in Hz.
    public var pitch: Double

    /// Loudness, `0...1`.
    public var gain: Double

    public init(pan: Double, pitch: Double, gain: Double) {
        self.pan = pan
        self.pitch = pitch
        self.gain = gain
    }
}

/// Turns direction into something the user hears.
public struct DirectionalAudio: Sendable {

    public init() {}

    /// The cue for a given guidance direction.
    ///
    /// - Parameter direction: unit vector from fingertip toward target, in panel
    ///   space. `+dx` is right, **`+dy` is down**.
    /// - Returns: the cue to render.
    ///
    /// Pure and synchronous on purpose — this is the part you can unit-test, and
    /// it is where the axis trap above gets caught.
    public func cue(for direction: PanelVector) -> AudioCue {
        fatalError("unimplemented — owned by Team 3 (ContourFeedback)")
    }

    /// Render the cue for `state`. Starts audio and returns.
    public func play(for state: GuidanceState) async {
        fatalError("unimplemented — owned by Team 3 (ContourFeedback)")
    }

    /// Stop anything currently playing. Must be safe to call when idle.
    public func stop() async {
        fatalError("unimplemented — owned by Team 3 (ContourFeedback)")
    }
}
