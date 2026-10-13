//
//  HapticEngineManager.swift
//  ContourFeedback — Experience / Haptics
//
//  Week 2 deliverable: "HapticEngineManager (continuous vibration you can
//  change live)."
//
//  Every vibration in Contour goes through this class. Guidance models, the
//  outcome signals, and haptics-only mode for deafblind users all call the same
//  four functions. It is deliberately small: it knows nothing about what a
//  vibration *means*, only how to make the phone do it and keep doing it.
//
//  THE PUBLIC API IS FROZEN (Fri Sep 25). These are the only public members:
//
//      start() throws
//      update(intensity:sharpness:)
//      tap(intensity:sharpness:)
//      stop()
//      isSupported
//
//  plus two read-only observables for the debug screen: `state` and
//  `resetCount`. Changing any signature needs the Experience lead's OK and a
//  Slack heads-up to every caller.
//
//  HOW IT WORKS
//  - One CHHapticEngine, held strongly for the life of the manager.
//  - The continuous vibration is a single `.hapticContinuous` event played
//    through a CHHapticAdvancedPatternPlayer with `loopEnabled`. A continuous
//    event can be at most 30 seconds long, which is why it loops.
//  - Live changes go through `sendParameters(_:atTime:)`. Intensity control
//    MULTIPLIES the event's base intensity and sharpness control ADDS to the
//    base sharpness, so the base event is built with intensity 1.0 and
//    sharpness 0.0 and the values you pass are the values you get.
//  - `tap` is a separate one-event transient pattern on its own player, so it
//    works while the continuous vibration is running.
//  - iOS kills haptic engines freely (background, phone lock, audio session
//    interruption). The reset handler restarts the engine AND rebuilds the
//    players — old players are dead after a reset. The stopped handler records
//    the reason. When the app returns to the foreground, the engine restarts if
//    it was running before.
//  - Every input is clamped to 0...1. A call containing NaN is ignored.
//
//  On hardware without haptics (and on macOS, where the Harness runs) every
//  call is a safe no-op and `isSupported` is false.
//

import Foundation
import Observation
import os

#if canImport(CoreHaptics)
import CoreHaptics
#endif

#if canImport(UIKit)
import UIKit
#endif

/// The single owner of the phone's haptic engine.
///
/// Create one, keep it alive, and route every vibration through it. Main-actor
/// bound because Core Haptics players are not thread-safe and SwiftUI wants to
/// observe `state` from the main thread anyway.
@MainActor
@Observable
public final class HapticEngineManager {

    // MARK: Public surface

    /// Where the engine is right now. For the debug screen and for tests.
    public enum State: String, Hashable, Sendable {
        /// This hardware cannot do haptics. Every call is a no-op.
        case unsupported
        /// Not vibrating. Either never started, stopped by a caller, or killed
        /// by the system and not yet resumed.
        case stopped
        /// The engine is up and the continuous player is looping.
        case running
    }

    /// Whether this device can play haptics at all.
    ///
    /// `false` on the Simulator, on iPads without a Taptic Engine, and on macOS.
    /// When `false`, `start()`, `update`, `tap` and `stop` all do nothing.
    public let isSupported: Bool

    /// The engine's current state.
    public private(set) var state: State

    /// How many times iOS has reset the engine underneath us. A number that
    /// climbs while the app is in the foreground is a bug worth chasing.
    public private(set) var resetCount = 0

    public init() {
        #if canImport(CoreHaptics)
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        isSupported = false
        #endif
        state = isSupported ? .stopped : .unsupported
        observeLifecycle()
    }

    isolated deinit {
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Start the engine and the continuous player.
    ///
    /// The continuous vibration begins at whatever intensity and sharpness were
    /// last passed to `update(intensity:sharpness:)`, which is silence (intensity
    /// 0) until someone asks for more. Safe to call when already running.
    ///
    /// - Throws: whatever Core Haptics throws when the engine cannot start.
    ///   Never throws on unsupported hardware — it just returns.
    public func start() throws {
        wantsRunning = true
        guard isSupported else { return }
        #if canImport(CoreHaptics)
        if state == .running { return }
        try startEngineIfNeeded()
        try startContinuousPlayer()
        state = .running
        #endif
    }

    /// Change the continuous vibration, live.
    ///
    /// - Parameters:
    ///   - intensity: how strong, `0...1`. Out-of-range values are clamped.
    ///   - sharpness: how crisp, `0...1`. Low is a dull hum, high is a buzz.
    ///
    /// A call with a NaN in either argument is ignored. Values are remembered
    /// even while stopped, so `update` then `start` behaves like `start` then
    /// `update`.
    public func update(intensity: Float, sharpness: Float) {
        guard let intensity = Self.clamped(intensity),
              let sharpness = Self.clamped(sharpness) else { return }
        currentIntensity = intensity
        currentSharpness = sharpness
        #if canImport(CoreHaptics)
        sendCurrentParameters()
        #endif
    }

    /// One short click, independent of the continuous vibration.
    ///
    /// Works whether or not `start()` has been called: the engine is brought up
    /// on demand if it is not already running.
    ///
    /// - Parameters:
    ///   - intensity: how strong, `0...1`. Clamped.
    ///   - sharpness: how crisp, `0...1`. Clamped.
    public func tap(intensity: Float, sharpness: Float) {
        guard let intensity = Self.clamped(intensity),
              let sharpness = Self.clamped(sharpness) else { return }
        guard isSupported else { return }
        #if canImport(CoreHaptics)
        do {
            try startEngineIfNeeded()
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try requireEngine().makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            logger.error("tap failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Stop everything. Safe to call when idle.
    public func stop() {
        wantsRunning = false
        guard isSupported else { return }
        #if canImport(CoreHaptics)
        stopContinuousPlayer()
        engine?.stop(completionHandler: nil)
        engineIsStarted = false
        state = .stopped
        #endif
    }

    // MARK: Internal state (visible to tests, not to callers)

    /// The last accepted intensity. Sent to the player on every start and reset.
    private(set) var currentIntensity: Float = 0

    /// The last accepted sharpness.
    private(set) var currentSharpness: Float = 0

    /// Whether a caller has asked for the continuous vibration and not yet
    /// asked for it to stop. This is what survives backgrounding and resets.
    private(set) var wantsRunning = false

    /// Clamp to `0...1`, or `nil` for NaN so the caller can ignore the call.
    static func clamped(_ value: Float) -> Float? {
        if value.isNaN { return nil }
        return min(max(value, 0), 1)
    }

    // MARK: Private

    private let logger = Logger(subsystem: "com.gtiosclub.contour", category: "haptics")

    @ObservationIgnored
    private var lifecycleObservers: [any NSObjectProtocol] = []

    #if canImport(CoreHaptics)

    /// The one engine. Created lazily on first use, then kept for good.
    @ObservationIgnored
    private var engine: CHHapticEngine?

    /// Whether `engine.start()` has succeeded and no stop or reset has happened
    /// since. Core Haptics does not expose this, so we track it ourselves.
    @ObservationIgnored
    private var engineIsStarted = false

    /// The looping continuous player. `nil` when stopped. Rebuilt after any reset
    /// because players do not survive one.
    @ObservationIgnored
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?

    /// Duration of the looped continuous event. Core Haptics caps a continuous
    /// event at 30 seconds. If you feel a hiccup at the loop point, this is the
    /// number to grow, up to that cap.
    private static let continuousEventDuration: TimeInterval = 30

    private func requireEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.resetHandler = { [weak self] in
            Task { @MainActor in self?.handleEngineReset() }
        }
        engine.stoppedHandler = { [weak self] reason in
            Task { @MainActor in self?.handleEngineStopped(reason) }
        }
        self.engine = engine
        return engine
    }

    private func startEngineIfNeeded() throws {
        let engine = try requireEngine()
        if engineIsStarted { return }
        try engine.start()
        engineIsStarted = true
    }

    private func startContinuousPlayer() throws {
        stopContinuousPlayer()
        let engine = try requireEngine()

        // Base intensity 1.0 and base sharpness 0.0 so that the dynamic controls
        // (multiply, add) map 0...1 straight onto what the user asked for.
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0),
            ],
            relativeTime: 0,
            duration: Self.continuousEventDuration
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        continuousPlayer = player

        try player.start(atTime: CHHapticTimeImmediate)
        sendCurrentParameters()
    }

    private func stopContinuousPlayer() {
        guard let player = continuousPlayer else { return }
        continuousPlayer = nil
        do {
            try player.stop(atTime: CHHapticTimeImmediate)
        } catch {
            // A player whose engine already died throws here. That is fine; it
            // was not going to vibrate anyway.
            logger.debug("stopping continuous player: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendCurrentParameters() {
        guard let player = continuousPlayer else { return }
        do {
            try player.sendParameters(
                [
                    CHHapticDynamicParameter(
                        parameterID: .hapticIntensityControl,
                        value: currentIntensity,
                        relativeTime: 0
                    ),
                    CHHapticDynamicParameter(
                        parameterID: .hapticSharpnessControl,
                        value: currentSharpness,
                        relativeTime: 0
                    ),
                ],
                atTime: CHHapticTimeImmediate
            )
        } catch {
            logger.error("sendParameters failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iOS reset the engine. Players are dead. Bring everything back if a caller
    /// still wants it.
    private func handleEngineReset() {
        resetCount += 1
        logger.notice("haptic engine reset (count \(self.resetCount, privacy: .public))")
        continuousPlayer = nil
        engineIsStarted = false
        state = .stopped
        resumeIfWanted()
    }

    /// The engine stopped for an external reason (app suspended, audio session
    /// interrupted, idle timeout, ...). Record it; the foreground hook resumes.
    private func handleEngineStopped(_ reason: CHHapticEngine.StoppedReason) {
        logger.notice("haptic engine stopped: \(Self.describe(reason), privacy: .public)")
        continuousPlayer = nil
        engineIsStarted = false
        if state == .running { state = .stopped }
    }

    private func resumeIfWanted() {
        guard wantsRunning, state != .running else { return }
        do {
            try start()
        } catch {
            logger.error("could not resume haptics: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func describe(_ reason: CHHapticEngine.StoppedReason) -> String {
        switch reason {
        case .audioSessionInterrupt: return "audioSessionInterrupt"
        case .applicationSuspended: return "applicationSuspended"
        case .idleTimeout: return "idleTimeout"
        case .notifyWhenFinished: return "notifyWhenFinished"
        case .engineDestroyed: return "engineDestroyed"
        case .gameControllerDisconnect: return "gameControllerDisconnect"
        case .systemError: return "systemError"
        @unknown default: return "unknown(\(reason.rawValue))"
        }
    }

    #endif

    /// Restart when the app comes back to the foreground, if a caller had it
    /// running. Done here rather than by asking every screen to forward
    /// `scenePhase`, so callers only ever need the four functions.
    private func observeLifecycle() {
        #if canImport(UIKit) && canImport(CoreHaptics)
        guard isSupported else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeIfWanted() }
        }
        lifecycleObservers.append(token)
        #endif
    }
}
