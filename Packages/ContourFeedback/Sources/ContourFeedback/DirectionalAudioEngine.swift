//
//  DirectionalAudioEngine.swift
//  ContourFeedback — Experience / Audio & Speech
//
//  Created by Asutosh Mishra on 10/4/26.
//
//  The hands-on tone API from #11, for the Directional Audio debug screen:
//  start, stop, point the beacon, set the volume. It is a thin face on
//  ToneEngine — the same graph, smoothing and recovery the guidance tone uses —
//  so what you hear on the debug screen is what guidance plays.
//
//  Note the mapping differs from DirectionalAudio's on purpose: here pitch
//  follows `proximity` (closer is higher), because the debug screen tests the
//  speaker and the pan, not the axis convention.
//

import Foundation

@MainActor
public final class DirectionalAudioEngine {

    // MARK: - Pitch mapping
    private struct PitchMapping {
        var minRate: Float = 0.75
        var maxRate: Float = 2.0
        func rate(for v: Float) -> Float { minRate * powf(maxRate / minRate, v) }
    }
    private let mapping = PitchMapping()

    /// Its own tone, separate from guidance's, so the debug screen never fights
    /// a running guidance session for the same voice.
    private let tone = ToneEngine(harmonic: false)

    public init() {
        tone.retarget(pan: 0, rate: mapping.minRate, gain: 1)
        tone.setVolume(0.5)
    }

    // MARK: - Public API (frozen Friday)

    /// Start the tone, fading in. Idempotent.
    public func start() throws {
        try tone.start()
    }

    /// Fade out, then halt. Safe to call when idle.
    public func stop() {
        tone.stop()
    }

    /// `pan` is -1 left ... +1 right; `proximity` 0 far (low) ... 1 close (high).
    /// Non-finite values are ignored.
    public func setBeacon(pan: Float, proximity: Float) {
        let rate = proximity.isFinite ? mapping.rate(for: min(max(proximity, 0), 1)) : nil
        tone.retarget(pan: pan, rate: rate)
    }

    /// `0...1`. Clamped; non-finite values are ignored.
    public func setVolume(_ volume: Float) {
        tone.setVolume(volume)
    }

    /// Restart after a route change if the tone is still wanted. ToneEngine
    /// already does this from AudioSessionConfig's events; this stays for callers.
    func handleRouteChange() {
        tone.restartIfWanted()
    }
}
