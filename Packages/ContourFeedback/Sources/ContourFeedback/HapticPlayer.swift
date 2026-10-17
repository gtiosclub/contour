//
//  HapticPlayer.swift
//  ContourFeedback — Experience / Haptics
//
//  Plays HapticEvents on the phone. Guidance models, the directional hint and
//  outcome signals share one of these, so everything goes through a single
//  HapticEngineManager.
//
//  Guidance vibration comes in two kinds, and the player runs at most one:
//
//  - PULSES (pulsedProximity) run on their own loop at the pulse rate, not at
//    camera rate: `pulse(forDistance:)` only updates the distance the next beat
//    uses, so it can be called every frame without restarting anything. Each
//    beat turns the manager's one looping continuous player up for a pulse
//    width and back down to silence.
//  - A SUSTAINED BUZZ (continuousProximity) is that same continuous player held
//    at a level: `sustain(_:)` sets it with `update(intensity:sharpness:)`. Near
//    the target it throbs between a strong and a weaker level, on a loop, but
//    never drops to silence.
//
//  Starting one kind stops the other, and `stopPulsing()` stops either, so a
//  model switched mid-run, an outcome, or a frame with no finger can never
//  leave a buzz stuck on. Nothing is created per beat or per frame, and because
//  the manager knows we want it running, it rebuilds that player after an
//  engine reset and resumes it — at the last level we set — when the app comes
//  back to the foreground. Outcome signals and directional hints are one-off
//  taps on top.
//

import Foundation

@MainActor
final class HapticPlayer {

    /// The one player LiveFeedbackEngine uses, so every engine — and every
    /// model switched in mid-run — drives the same haptic engine.
    nonisolated static let shared = HapticPlayer()

    /// Created on first use so constructing the package's types stays cheap
    /// and off the main actor. Readable for tests.
    private(set) var manager: HapticEngineManager?
    private var guidance: Guidance?
    private var guidanceLoop: Task<Void, Never>?
    private var signal: Task<Void, Never>?

    /// The guidance vibration currently playing.
    private enum Guidance: Equatable {
        case pulsing(distance: Double)
        case sustained(SustainedBuzz)
    }

    nonisolated init() {}

    /// Whether proximity pulses are currently playing. For tests.
    var isPulsing: Bool {
        if case .pulsing = guidance { return true }
        return false
    }

    /// Whether the sustained buzz is currently playing. For tests.
    var isSustaining: Bool {
        if case .sustained = guidance { return true }
        return false
    }

    /// Keep pulsing for `distance`. The running loop picks up the new distance
    /// on its next beat. Stops a sustained buzz first.
    func pulse(forDistance distance: Double) {
        guard distance.isFinite else { return stopPulsing() }
        if isPulsing {
            guidance = .pulsing(distance: distance)
            return
        }
        cancelGuidanceLoop()
        guidance = .pulsing(distance: distance)

        let engine = requireManager()
        // Start silent; the first beat sets the level. If the engine cannot
        // start right now (say, the app is in the background), the manager
        // still remembers we want it and resumes on the next foreground.
        engine.update(intensity: 0, sharpness: 0)
        try? engine.start()

        guidanceLoop = Task { [weak self] in
            while !Task.isCancelled, let self, case .pulsing(let distance) = self.guidance {
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

    /// Hold the continuous vibration at `buzz`. Call it every frame: a steady
    /// buzz is re-applied each time, and a throbbing one keeps its loop and
    /// picks up the new level. Stops pulses first.
    func sustain(_ buzz: SustainedBuzz) {
        guard buzz.intensity.isFinite, buzz.sharpness.isFinite else { return stopPulsing() }
        var wasThrobbing = false
        if case .sustained(let previous) = guidance {
            wasThrobbing = previous.throbPeriod != nil
        } else {
            cancelGuidanceLoop()   // a pulse loop must not keep toggling the level
        }
        let wasSustaining = isSustaining
        guidance = .sustained(buzz)

        let engine = requireManager()
        if buzz.throbPeriod != nil {
            if !wasThrobbing { startThrob(on: engine) }
        } else {
            if wasThrobbing { cancelGuidanceLoop() }
            engine.update(intensity: Float(buzz.intensity), sharpness: Float(buzz.sharpness))
        }
        if !wasSustaining { try? engine.start() }
    }

    /// Stop guidance vibration, pulsed or sustained. Safe to call every frame
    /// while idle: the engine is only touched if something was actually
    /// playing, so an outcome signal that is still tapping is not cut off by
    /// the frames that follow it.
    func stopPulsing() {
        guard guidance != nil else { return }
        guidance = nil
        cancelGuidanceLoop()
        // Silence first, so the next start() doesn't open at the last level.
        manager?.update(intensity: 0, sharpness: 0)
        manager?.stop()
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

    private func startThrob(on engine: HapticEngineManager) {
        cancelGuidanceLoop()
        guidanceLoop = Task { [weak self] in
            var strong = true
            while !Task.isCancelled, let self,
                  case .sustained(let buzz) = self.guidance, let period = buzz.throbPeriod {
                let intensity = strong ? buzz.intensity : buzz.intensity * GuidanceTuning.throbDip
                engine.update(intensity: Float(intensity), sharpness: Float(buzz.sharpness))
                strong.toggle()
                try? await Task.sleep(for: period / 2)
            }
        }
    }

    private func cancelGuidanceLoop() {
        guidanceLoop?.cancel()
        guidanceLoop = nil
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
