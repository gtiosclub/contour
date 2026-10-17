//
//  DirectionalAudio.swift
//  ContourFeedback — Experience / Audio & Speech
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
//  THE MAPPING
//    pan    from dx: hard left at dx = -1, hard right at dx = +1
//    pitch  from -dy: 960 Hz when the target is straight up, 360 Hz straight down
//    gain   from normalizedDistance: 1 on the target, `minimumGain` at
//           `farDistance` (the far corner of the panel) and beyond
//  All of it is pure and unit-tested. Playing it goes through ToneEngine, which
//  this shares with DirectionalAudioEngine.
//
import ContourCore
import Foundation

/// One moment of the tone, described independently of AVAudioEngine.
public struct AudioCue: Hashable, Sendable {
    /// `-1` hard left ... `+1` hard right.
    public var pan: Double
    /// Hz.
    public var pitch: Double
    /// `0...1`.
    public var gain: Double
    public init(pan: Double, pitch: Double, gain: Double) {
        self.pan = pan; self.pitch = pitch; self.gain = gain
    }
}

public struct DirectionalAudio: Sendable {

    /// Pitch range in Hz (matches the 0.75...2.0 varispeed range on a 480 Hz tone).
    public static let lowPitch: Double = 360    // target is straight DOWN
    public static let highPitch: Double = 960   // target is straight UP

    /// Distance at (or beyond) which the cue is at its quietest, in
    /// `GuidanceVector.normalizedDistance` units: 1 is the far corner of the panel.
    public let farDistance: Double
    /// Floor so a far target is still audible; the user can't see that it's silent.
    public let minimumGain: Double

    /// The tone this plays through. Shared by default, so every engine drives
    /// the same one and switching engines can never leave a second tone running.
    let tone: ToneEngine

    public init(farDistance: Double = 1, minimumGain: Double = 0.2) {
        self.init(farDistance: farDistance, minimumGain: minimumGain, tone: .guidance)
    }

    init(farDistance: Double = 1, minimumGain: Double = 0.2, tone: ToneEngine) {
        // A zero or negative far distance would divide by zero in gain(forDistance:).
        self.farDistance = farDistance.isFinite && farDistance > 0 ? farDistance : 1
        self.minimumGain = minimumGain.isFinite ? min(max(minimumGain, 0), 1) : 0.2
        self.tone = tone
    }

    // MARK: - Pure mapping (unit-tested)

    /// Direction only: pan from dx, pitch from dy, gain 1.0 because a unit vector has no distance.
    public func cue(for direction: PanelVector) -> AudioCue {
        let dx = Double(direction.dx)
        let dy = Double(direction.dy)

        let pan = dx.isFinite ? min(max(dx, -1), 1) : 0

        // THE AXIS TRAP: +dy is DOWN, so "up" is -dy. Negate before mapping to pitch.
        let up = dy.isFinite ? min(max(-dy, -1), 1) : 0     // -1 down ... +1 up
        let t = (up + 1) / 2                                 // 0 down ... 1 up
        let pitch = Self.lowPitch * pow(Self.highPitch / Self.lowPitch, t)  // equal steps = equal musical intervals

        return AudioCue(pan: pan, pitch: pitch, gain: 1)
    }

    /// Direction plus distance: closer is louder.
    public func cue(for direction: PanelVector, distance: Double) -> AudioCue {
        var cue = self.cue(for: direction)
        cue.gain = gain(forDistance: distance)
        return cue
    }

    public func gain(forDistance distance: Double) -> Double {
        guard distance.isFinite else { return minimumGain }
        let closeness = 1 - min(max(distance / farDistance, 0), 1)   // 1 at the target, 0 when far
        return minimumGain + (1 - minimumGain) * closeness
    }

    /// The cue for one guidance state, or `nil` when the tone should be silent:
    /// no vector, or the state is terminal. The only place that reads
    /// GuidanceState's shape, and the exact cue `play(for:)` renders.
    func cue(for state: GuidanceState) -> AudioCue? {
        guard !state.isTerminal, let vector = state.vector else { return nil }
        return cue(for: vector.direction, distance: vector.normalizedDistance)
    }

    // MARK: - Rendering

    /// Retargets the tone and returns. Cheap enough to call on every guidance update.
    /// A state with no vector, or a terminal one, fades the tone out.
    public func play(for state: GuidanceState) async {
        guard let cue = cue(for: state) else {
            await tone.stop()
            return
        }
        await play(cue)
    }

    /// Head for `cue`, starting the tone if needed.
    func play(_ cue: AudioCue) async {
        await tone.render(cue)
    }

    /// Fades out and halts. Safe to call when idle.
    public func stop() async {
        await tone.stop()
    }

    /// Play an earcon once through the same engine, centred. Starts it and
    /// returns. Does not stop the tone — an outcome does that itself.
    public func play(_ earcon: Earcon) async {
        await tone.play(earcon)
    }
}
