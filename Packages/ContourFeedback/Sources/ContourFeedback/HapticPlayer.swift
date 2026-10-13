//
//  HapticPlayer.swift
//  ContourFeedback — Experience / Haptics
//
//  Plays HapticEvents on the phone. Proximity pulses and outcome signals share
//  one of these, so everything goes through a single HapticEngineManager.
//
//  Proximity pulses run on their own loop at the pulse rate, not at camera
//  rate: `pulse(forDistance:)` only updates the distance the next beat uses, so
//  it can be called every frame without restarting anything.
//

import Foundation

@MainActor
final class HapticPlayer {

    /// Created on first use so constructing the package's types stays cheap
    /// and off the main actor.
    private var manager: HapticEngineManager?
    private var distance: Double?
    private var pulseLoop: Task<Void, Never>?
    private var signal: Task<Void, Never>?

    nonisolated init() {}

    /// Whether proximity pulses are currently playing. For tests.
    var isPulsing: Bool { pulseLoop != nil }

    /// Keep pulsing for `distance`. The running loop picks up the new distance
    /// on its next beat.
    func pulse(forDistance distance: Double) {
        guard distance.isFinite else { return stopPulsing() }
        self.distance = distance
        guard pulseLoop == nil else { return }

        pulseLoop = Task { [weak self] in
            while !Task.isCancelled, let self, let distance = self.distance {
                if let beat = ProximityHaptics.beat(forDistance: distance) {
                    self.tap(beat)
                }
                try? await Task.sleep(for: ProximityHaptics.pulseInterval(forDistance: distance))
            }
        }
    }

    func stopPulsing() {
        distance = nil
        pulseLoop?.cancel()
        pulseLoop = nil
    }

    /// Play `events` once, at their offsets. A new signal replaces one still
    /// playing.
    func play(_ events: [HapticEvent]) {
        signal?.cancel()
        signal = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            for event in events {
                try? await clock.sleep(until: start + event.time)
                guard !Task.isCancelled, let self else { return }
                self.tap(event)
            }
        }
    }

    private func tap(_ event: HapticEvent) {
        let engine = manager ?? HapticEngineManager()
        manager = engine
        engine.tap(intensity: Float(event.intensity), sharpness: Float(event.sharpness))
    }
}
