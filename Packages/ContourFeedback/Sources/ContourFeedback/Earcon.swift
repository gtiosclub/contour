//
//  Earcon.swift
//  ContourFeedback — Experience / Outcome Signals & Harness
//
//  A short sound that means one thing (#115). OutcomeAnnouncer gives each of
//  the four outcomes one; ToneEngine plays them through the same AVAudioEngine
//  as the guidance tone.
//
//  An earcon is a handful of notes, described independently of AVAudioEngine so
//  tests can pin that the four are different and that notFound does not sound
//  like lowConfidence. `samples(sampleRate:)` turns it into mono audio: every
//  note fades in over 5 ms and out over 20 ms, so nothing clicks, and each note
//  carries its 2nd and 3rd harmonics so a low note still comes through a phone
//  speaker that cannot reproduce its fundamental.
//

import Foundation

/// One note of an earcon.
public struct EarconNote: Hashable, Sendable {

    /// Offset from the start of the earcon.
    public var start: Duration

    /// How long the note sounds, including its fades.
    public var duration: Duration

    /// Pitch at the start of the note, in Hz.
    public var frequency: Double

    /// Pitch at the end, in Hz. Equal to `frequency` for a steady note; anything
    /// else glides between the two.
    public var endFrequency: Double

    /// Level at the start of the note, `0...1`.
    public var gain: Double

    /// Level at the end, `0...1`. Lower than `gain` for a note that dies away.
    public var endGain: Double

    public init(
        start: Duration,
        duration: Duration,
        frequency: Double,
        endFrequency: Double? = nil,
        gain: Double,
        endGain: Double? = nil
    ) {
        self.start = start
        self.duration = duration
        self.frequency = frequency
        self.endFrequency = endFrequency ?? frequency
        self.gain = gain
        self.endGain = endGain ?? gain
    }
}

/// A short sound that means one thing.
public struct Earcon: Hashable, Sendable {

    /// The notes, earliest first.
    public var notes: [EarconNote]

    public init(notes: [EarconNote]) {
        self.notes = notes
    }

    /// From the first note's start to the last note's end.
    public var duration: Duration {
        notes.map { $0.start + $0.duration }.max() ?? .zero
    }

    // MARK: Rendering

    /// Fade-in and fade-out on every note, in seconds.
    static let attack = 0.005
    static let release = 0.020
    /// Harmonic levels relative to the fundamental: 2nd, 3rd.
    static let harmonics = [0.5, 0.25]
    /// Headroom, so overlapping notes cannot clip.
    static let masterGain = 0.8

    /// The earcon as mono samples in `-1...1`.
    ///
    /// Pure and synchronous on purpose — this is the part you can unit-test.
    func samples(sampleRate: Double = LoopTone.sampleRate) -> [Float] {
        let frameCount = Int((Self.seconds(duration) * sampleRate).rounded(.up))
        guard frameCount > 0 else { return [] }
        var mix = [Double](repeating: 0, count: frameCount)
        let normalizer = 1 + Self.harmonics.reduce(0, +)

        for note in notes {
            let start = Int((Self.seconds(note.start) * sampleRate).rounded())
            let length = Int((Self.seconds(note.duration) * sampleRate).rounded())
            guard length > 1 else { continue }
            let total = Double(length - 1) / sampleRate
            var phase = 0.0
            for frame in 0..<length where start + frame < frameCount {
                let t = Double(frame) / sampleRate
                let progress = t / total
                let frequency = note.frequency + (note.endFrequency - note.frequency) * progress
                let level = note.gain + (note.endGain - note.gain) * progress
                let envelope = Self.fade(t / Self.attack) * Self.fade((total - t) / Self.release)

                var value = sin(phase)
                for (index, harmonic) in Self.harmonics.enumerated() {
                    value += harmonic * sin(Double(index + 2) * phase)
                }
                mix[start + frame] += value / normalizer * level * envelope
                phase += 2 * Double.pi * frequency / sampleRate
            }
        }
        return mix.map { Float(min(max($0 * Self.masterGain, -1), 1)) }
    }

    /// Raised-cosine ramp: 0 at x ≤ 0, 1 at x ≥ 1, smooth in between.
    private static func fade(_ x: Double) -> Double {
        guard x < 1 else { return 1 }
        guard x > 0 else { return 0 }
        return 0.5 - 0.5 * cos(Double.pi * x)
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}
