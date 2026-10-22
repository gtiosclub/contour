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
//  Pulses play through the manager's one looping continuous player: each beat
//  turns its intensity up for a pulse width and back down to silence. Nothing
//  is created per beat or per frame, and because the manager knows we want it
//  running, it rebuilds that player after an engine reset and resumes it when
//  the app comes back to the foreground. Outcome signals and direction cues
//  are one-off taps, and the pulses go quiet while one plays.
//

import Foundation

@MainActor
final class HapticPlayer {

    /// Created on first use so constructing the package's types stays cheap
    /// and off the main actor. Readable for tests.
    private(set) var manager: HapticEngineManager?
    private var distance: Double?
    private var pulseLoop: Task<Void, Never>?
    private var signal: Task<Void, Never>?

    /// The pulses skip their beats until then, so a signal or a direction cue
    /// is felt on its own rather than blurred into the buzz.
    private var quietUntil: ContinuousClock.Instant?

    /// How long the pulses stay quiet after a signal's last tap.
    static let quietAfterSignal: Duration = .milliseconds(150)

    nonisolated init() {}

    /// Whether proximity pulses are currently playing. For tests.
    var isPulsing: Bool { pulseLoop != nil }

    /// Whether a signal or cue is still playing, plus its quiet tail.
    var isPlayingSignal: Bool {
        quietUntil.map { ContinuousClock.now < $0 } ?? false
    }

    /// Keep pulsing for `distance`. The running loop picks up the new distance
    /// on its next beat.
    func pulse(forDistance distance: Double) {
        guard distance.isFinite else { return stopPulsing() }
        self.distance = distance
        guard pulseLoop == nil else { return }

        let engine = requireManager()
        // Start silent; the first beat sets the level. If the engine cannot
        // start right now (say, the app is in the background), the manager
        // still remembers we want it and resumes on the next foreground.
        engine.update(intensity: 0, sharpness: 0)
        try? engine.start()

        pulseLoop = Task { [weak self] in
            while !Task.isCancelled, let self, let distance = self.distance {
                if let quietUntil = self.quietUntil, ContinuousClock.now < quietUntil {
                    try? await Task.sleep(until: quietUntil, clock: .continuous)
                    continue
                }
                let interval = ProximityHaptics.pulseInterval(forDistance: distance)
                guard let beat = ProximityHaptics.beat(forDistance: distance) else {
                    try? await Task.sleep(for: interval)
                    continue
                }
                let width = ProximityHaptics.pulseWidth(forDistance: distance)
                let sharpness = Float(beat.sharpness)
                engine.update(intensity: Float(beat.intensity), sharpness: sharpness)
                try? await Task.sleep(for: width)
                guard !Task.isCancelled else { return }
                engine.update(intensity: 0, sharpness: sharpness)
                try? await Task.sleep(for: interval - width)
            }
        }
    }

    /// Stop the pulses. Safe to call every frame while idle: the engine is only
    /// touched if pulses were actually playing, so an outcome signal that is
    /// still tapping is not cut off by the frames that follow it.
    func stopPulsing() {
        distance = nil
        guard let loop = pulseLoop else { return }
        loop.cancel()
        pulseLoop = nil
        // Silence first, so the next start() doesn't open at the last beat.
        manager?.update(intensity: 0, sharpness: 0)
        manager?.stop()
    }

    /// Play `events` once, at their offsets. A new signal replaces one still
    /// playing. Proximity pulses go quiet until it is over.
    func play(_ events: [HapticEvent]) {
        signal?.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        quietUntil = start + (events.map(\.time).max() ?? .zero) + Self.quietAfterSignal
        // Cut a pulse that is mid-buzz, so the first tap lands on silence.
        manager?.update(intensity: 0, sharpness: 0)
        signal = Task { [weak self] in
            for event in events {
                try? await clock.sleep(until: start + event.time)
                guard !Task.isCancelled, let self else { return }
                self.tap(event)
            }
        }
    }

    private func tap(_ event: HapticEvent) {
        requireManager().tap(intensity: Float(event.intensity), sharpness: Float(event.sharpness))
    }

    private func requireManager() -> HapticEngineManager {
        if let manager { return manager }
        let manager = HapticEngineManager()
        self.manager = manager
        return manager
    }
}
