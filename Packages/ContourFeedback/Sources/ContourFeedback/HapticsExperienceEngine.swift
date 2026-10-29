//  HapticsExperienceEngine.swift
//  ContourFeedback — Experience prototype
//  Experience Subteam - Evan

import CoreHaptics
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Far: discrete beats. Near: a continuous hum with distance-driven strength
/// and sharpness. The user-selected intensity sets the maximum strength.
/// Sharpness describes texture, not a vibration frequency in Hz.
/// Retain for a session; stop when guidance ends or becomes unreliable.
@MainActor
@Observable
public final class HapticsExperienceEngine {
    public enum Mode: String, Sendable {
        case pulsed = "Pulses"
        case continuous = "Continuous"
    }

    public private(set) var distance: Double?
    public private(set) var isRunning = false
    public private(set) var mode: Mode = .pulsed
    public private(set) var overallIntensity = 0.85
    public private(set) var intensity = 0.0
    /// A successful player start, not a measurement of physical motor output.
    public private(set) var continuousPlayerActive = false
    public private(set) var sharpness = 0.0
    public private(set) var lastError: String?
    public let isSupported: Bool

    /// Cadence of discrete beats, not the physical frequency of the actuator.
    public var frequencyHz: Double? {
        distance.flatMap { Self.frequency(for: $0) }
    }

    #if os(iOS)
    @ObservationIgnored private let successFeedback = UINotificationFeedbackGenerator()
    #endif
    @ObservationIgnored private let onPulse: (@MainActor () -> Void)?
    @ObservationIgnored private var hardwareEngine: CHHapticEngine?
    @ObservationIgnored private var continuousPlayer: (any CHHapticAdvancedPatternPlayer)?
    @ObservationIgnored private var beatPlayer: (any CHHapticPatternPlayer)?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var lastBeat: ContinuousClock.Instant?
    @ObservationIgnored private var lastRender: ContinuousClock.Instant?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var continuousID: UUID?
    @ObservationIgnored private var beatIntensity: Double?
    @ObservationIgnored private var externallyClocked = false

    /// An injected callback observes beats without creating a hardware engine.
    public init(onPulse: (@MainActor () -> Void)? = nil) {
        self.onPulse = onPulse
        #if os(iOS)
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        isSupported = false
        #endif
    }

    isolated deinit {
        renderTask?.cancel()
        hardwareEngine?.stop(completionHandler: nil)
    }

    /// Matches the audio cadence: d=0 → 6 Hz, d=0.5 → 3.5 Hz, d>=1 → 1 Hz.
    public nonisolated static func frequency(for distance: Double) -> Double? {
        guard distance.isFinite, distance >= 0 else { return nil }
        let proximity = 1 - min(distance, 1)
        return 1 + 5 * proximity * proximity * (3 - 2 * proximity)
    }

    /// Hysteresis: enter the near zone at 0.25, leave it at 0.30. The default
    /// when starting between those values is pulsed.
    public nonisolated static func mode(for distance: Double, previous: Mode = .pulsed) -> Mode? {
        guard frequency(for: distance) != nil else { return nil }
        switch previous {
        case .pulsed: return distance <= 0.25 ? .continuous : .pulsed
        case .continuous: return distance >= 0.30 ? .pulsed : .continuous
        }
    }

    public nonisolated static func continuousParameters(for distance: Double, intensity: Double = 0.85) -> (intensity: Double, sharpness: Double)? {
        guard frequency(for: distance) != nil, intensity.isFinite else { return nil }
        let proximity = 1 - min(distance / 0.30, 1)
        let eased = proximity * proximity * (3 - 2 * proximity)
        let maximumIntensity = min(max(intensity, 0), 1)
        return (maximumIntensity * (0.70 + 0.30 * eased), 0.20 + 0.65 * eased)
    }

    /// Sets far-tap strength and the upper limit for the near hum. Near intensity
    /// varies from 70% to 100% of this setting as distance decreases.
    /// A setting of zero mutes hardware output without changing channel settings.
    public func setIntensity(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0), 1)
        guard overallIntensity != clamped else { return }
        overallIntensity = clamped
        // Rebuild the cached tap at its next shared beat, with the selected gain.
        try? beatPlayer?.stop(atTime: CHHapticTimeImmediate)
        beatPlayer = nil
        beatIntensity = nil
        guard isRunning else { return }
        do {
            try synchronizeContinuousOutput()
        } catch {
            fail(error)
        }
    }

    /// With an external clock, the caller supplies far beats using pulse(at:).
    /// The internal loop only smooths continuous parameters and checks lifecycle.
    public func start(distance: Double, externallyClocked: Bool = false) {
        update(distance: distance)
        guard self.distance != nil, !isRunning else { return }
        lastError = nil
        guard isSupported || onPulse != nil else {
            lastError = "This device does not support haptics."
            return
        }
        self.externallyClocked = externallyClocked
        mode = Self.mode(for: distance) ?? .pulsed
        do {
            if onPulse == nil { try prepareHardware() }
            #if os(iOS)
            successFeedback.prepare()
            #endif
            isRunning = true
            try synchronizeContinuousOutput()
            lastBeat = nil
            lastRender = nil
            renderTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let shouldContinue = self?.tick(), shouldContinue else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(20))
                    } catch {
                        return
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    public func update(distance: Double?) {
        guard let distance, let nextMode = Self.mode(for: distance, previous: mode) else {
            stop()
            return
        }
        self.distance = distance
        if nextMode != mode {
            // Cancel any queued far beat before entering continuous feedback.
            if nextMode == .continuous { try? beatPlayer?.stop(atTime: CHHapticTimeImmediate) }
            mode = nextMode
        }
        guard isRunning else { return }
        do {
            try synchronizeContinuousOutput()
        } catch {
            fail(error)
        }
    }

    /// Schedule one far-zone pulse at a shared monotonic system-uptime time.
    /// Pair with AudioExperienceEngine.playPulse(at:) for synchronized feedback.
    /// Near-zone calls are intentionally silent: the continuous player takes over.
    public func pulse(at uptime: TimeInterval) {
        guard isRunning, mode == .pulsed, overallIntensity > 0, uptime.isFinite else { return }
        if let onPulse {
            onPulse()
            return
        }
        guard let hardwareEngine else { return }
        do {
            if beatPlayer == nil || beatIntensity != overallIntensity {
                let beat = CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(overallIntensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                ], relativeTime: 0)
                beatPlayer = try hardwareEngine.makePlayer(with: CHHapticPattern(events: [beat], parameters: []))
                beatIntensity = overallIntensity
            }
            guard let beatPlayer else { return }
            let delay = max(0, uptime - ProcessInfo.processInfo.systemUptime)
            try beatPlayer.start(atTime: hardwareEngine.currentTime + delay)
        } catch {
            fail(error)
        }
    }

    /// Ends proximity feedback and emits the standard iOS success notification.
    /// Its system-defined strength is not scalable; a zero overall setting mutes it.
    /// The caller decides when arrival occurs and ensures one signal per arrival.
    public func playSuccess() {
        stop()
        guard isSupported, overallIntensity > 0, onPulse == nil else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        successFeedback.notificationOccurred(.success)
        #endif
    }

    public func stop() {
        isRunning = false
        sessionID = nil
        renderTask?.cancel()
        renderTask = nil
        try? beatPlayer?.stop(atTime: CHHapticTimeImmediate)
        stopContinuousOutput()
        hardwareEngine?.stop(completionHandler: nil)
        hardwareEngine = nil
        continuousPlayer = nil
        beatPlayer = nil
        beatIntensity = nil
        distance = nil
        intensity = 0
        sharpness = 0
        mode = .pulsed
        lastBeat = nil
        lastRender = nil
    }

    private func tick() -> Bool {
        guard isRunning, let distance, let frequencyHz else { return false }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            stop()
            return false
        }
        #endif
        let now = ContinuousClock.now
        let elapsed = lastRender.map { $0.duration(to: now) }
        let dt = elapsed.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0.02
        lastRender = now
        let target = Self.continuousParameters(for: distance, intensity: overallIntensity)!
        let blend = 1 - exp(-max(0, dt) / 0.06)
        // Ease texture changes; the smooth distance curve also scales strength
        // within 70–100% of the selected maximum.
        if mode == .continuous {
            sharpness += (target.sharpness - sharpness) * blend
        }
        do {
            try synchronizeContinuousOutput()
        } catch {
            fail(error)
            return false
        }
        if !externallyClocked, mode == .pulsed,
           lastBeat == nil || now >= lastBeat!.advanced(by: .seconds(1 / frequencyHz)) {
            lastBeat = now
            pulse(at: ProcessInfo.processInfo.systemUptime + 0.04)
        }
        return isRunning
    }

    private func prepareHardware() throws {
        let engine = try CHHapticEngine()
        hardwareEngine = engine
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = false
        let id = UUID()
        sessionID = id
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.interrupted(session: id) }
        }
        engine.stoppedHandler = { [weak self] reason in
            Task { @MainActor in self?.interrupted(session: id, reason: String(describing: reason)) }
        }
        try engine.start()
        // No silent background player. The near player is created and started
        // explicitly on entry, with no embedded zero-intensity control.
    }

    private func synchronizeContinuousOutput() throws {
        intensity = overallIntensity
        guard mode == .continuous, overallIntensity > 0, let distance else {
            stopContinuousOutput()
            return
        }
        let target = Self.continuousParameters(for: distance, intensity: overallIntensity)!
        intensity = target.intensity
        if onPulse != nil {
            continuousPlayerActive = true
            return
        }
        guard let hardwareEngine else { return }
        if continuousPlayer == nil {
            sharpness = target.sharpness
            let hum = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0),
            ], relativeTime: 0, duration: 30)
            // Start at full base intensity. Apply the nonzero user gain after
            // start, as in Apple's interactive continuous-haptics workflow.
            // Avoid a zero control embedded in the looping pattern itself.
            let pattern = try CHHapticPattern(events: [hum], parameters: [])
            let player = try hardwareEngine.makeAdvancedPlayer(with: pattern)
            let id = UUID()
            continuousID = id
            continuousPlayer = player
            player.loopEnabled = true
            player.loopEnd = 30
            player.isMuted = false
            player.completionHandler = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.continuousID == id, self.isRunning else { return }
                    self.stop()
                    self.lastError = error.map { Self.describe($0) }
                        ?? "Continuous haptics ended unexpectedly. Press Start to retry."
                }
            }
            try player.start(atTime: CHHapticTimeImmediate)
            continuousPlayerActive = true
        }
        try continuousPlayer?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(intensity), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(sharpness), relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    private func stopContinuousOutput() {
        // Invalidate callbacks before intentionally stopping an old player.
        continuousID = nil
        continuousPlayerActive = false
        try? continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        continuousPlayer = nil
    }

    private func fail(_ error: any Error) {
        stop()
        lastError = Self.describe(error)
    }

    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain): \(error.code))"
    }

    private func interrupted(session: UUID, reason: String = "engine reset") {
        guard sessionID == session, isRunning else { return }
        stop()
        lastError = "Haptics stopped: \(reason). Press Start to resume."
    }
}
