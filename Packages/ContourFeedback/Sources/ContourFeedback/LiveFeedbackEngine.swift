import Combine
import ContourCore
import Foundation
import Observation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Shared playback coordinator for live guidance and the experience test pad.
/// Owns the beat clock; present only updates playback and never waits for an effect.
@MainActor
@Observable
public final class LiveFeedbackEngine: FeedbackEngine {
    @ObservationIgnored private lazy var audioOutput = AudioExperienceEngine()
    @ObservationIgnored private lazy var voiceOutput = VoiceExperienceEngine()
    @ObservationIgnored private lazy var hapticOutput = HapticsExperienceEngine()
    @ObservationIgnored private let outcomePlayer = HapticPlayer()
    @ObservationIgnored private var beatTask: Task<Void, Never>?
    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var freshnessTask: Task<Void, Never>?
    @ObservationIgnored private var receivedAt: ContinuousClock.Instant?
    private var direction = ExperienceDirectionInstruction()
    private var current: GuidanceState?
    public private(set) var audioEnabled = true
    public private(set) var voiceEnabled = true
    public private(set) var hapticsEnabled = true
    public private(set) var didReachTarget = false
    public private(set) var instructionText = "Press Start to begin."

    // Read-only references expose channel diagnostics to the test screen.
    public var audio: AudioExperienceEngine { audioOutput }
    public var voice: VoiceExperienceEngine { voiceOutput }
    public var haptics: HapticsExperienceEngine { hapticOutput }

    /// Construction remains cheap and available to callers outside the main actor.
    public nonisolated init() {}

    /// Internal seam for exercising routing and the shared clock without hardware.
    init(haptics: HapticsExperienceEngine) { hapticOutput = haptics }

    isolated deinit { beatTask?.cancel(); freshnessTask?.cancel() }

    public func present(_ state: GuidanceState) async {
        observeLifecycle()
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { stop(); return }
        #endif
        if let outcome = state.outcome {
            guard current?.outcome != outcome else { return }
            stopPlayback()
            direction = ExperienceDirectionInstruction()
            current = state
            didReachTarget = outcome == .arrived
            instructionText = outcome == .arrived ? "Target reached." : "Guidance paused."
            if voiceEnabled, outcome == .arrived || outcome == .lostTracking {
                try? voiceOutput.start()
                voiceOutput.update(outcome == .arrived ? .arrived : .paused,
                                   distance: 0, at: ProcessInfo.processInfo.systemUptime)
            }
            if outcome == .arrived {
                if audioEnabled { try? audioOutput.playSuccess() }
                if hapticsEnabled { hapticOutput.playSuccess() }
            } else if hapticsEnabled {
                // Preserve existing non-arrival signals until the outcome lane replaces them.
                outcomePlayer.play(OutcomeAnnouncer().presentation(for: outcome).haptics)
            }
            return
        }
        guard let vector = state.vector, vector.normalizedDistance.isFinite,
              vector.normalizedDistance >= 0, vector.direction.dx.isFinite,
              vector.direction.dy.isFinite else {
            stop()
            instructionText = "Guidance paused."
            return
        }
        if current?.outcome != nil { stopPlayback(); direction = ExperienceDirectionInstruction() }
        current = state
        receivedAt = .now
        startFreshnessWatch()
        didReachTarget = false
        render(vector)
        startBeatClock()
    }

    /// Disabled channels stop immediately; enabled channels use only current guidance.
    public func setChannels(audio: Bool, voice: Bool, haptics: Bool, intensity: Double = 0.85) {
        audioEnabled = audio
        voiceEnabled = voice
        hapticsEnabled = haptics
        hapticOutput.setIntensity(intensity)
        if !audio { audioOutput.stop() }
        if !voice { voiceOutput.stop() }
        if !haptics { hapticOutput.stop(); outcomePlayer.stop() }
        if let current, current.outcome == nil, let vector = current.vector {
            render(vector)
            startBeatClock()
        }
        if !audio && !voice && !haptics { beatTask?.cancel(); beatTask = nil }
    }

    /// Idempotent session cleanup. A later present must supply fresh guidance.
    public func stop() {
        stopPlayback()
        current = nil
        direction = ExperienceDirectionInstruction()
        didReachTarget = false
        instructionText = "Press Start to begin."
    }

    private func stopPlayback() {
        beatTask?.cancel()
        beatTask = nil
        freshnessTask?.cancel()
        freshnessTask = nil
        receivedAt = nil
        audioOutput.stop()
        voiceOutput.stop()
        hapticOutput.stop()
        outcomePlayer.stop()
    }

    private func render(_ vector: GuidanceVector) {
        if vector.normalizedDistance == 0 {
            beatTask?.cancel()
            beatTask = nil
            audioOutput.stop()
            if voiceEnabled {
                try? voiceOutput.start()
                voiceOutput.update(.holding, distance: 0, at: ProcessInfo.processInfo.systemUptime)
            }
            instructionText = "Stop. Hold here."
            if hapticsEnabled { hapticOutput.holdOnTarget() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        direction.update(vector, at: now)
        instructionText = direction.text
        if voiceEnabled {
            try? voiceOutput.start()
            voiceOutput.update(direction.voiceGuidance, distance: vector.normalizedDistance, at: now)
        }
        if audioEnabled { try? audioOutput.start(distance: vector.normalizedDistance, externallyClocked: true) }
        if hapticsEnabled { hapticOutput.start(distance: vector.normalizedDistance, externallyClocked: true) }
    }

    private func startBeatClock() {
        guard current?.vector?.normalizedDistance != 0, beatTask == nil, audioOutput.isRunning || hapticOutput.isRunning else { return }
        beatTask = Task { @MainActor [weak self] in
            var lastBeat: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard self?.playBeat(lastBeat: &lastBeat) == true else { break }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            self?.beatTask = nil
        }
    }

    private func playBeat(lastBeat: inout ContinuousClock.Instant?) -> Bool {
        guard let vector = current?.vector, current?.outcome == nil,
              audioOutput.isRunning || hapticOutput.isRunning,
              let frequency = AudioExperienceEngine.frequency(for: vector.normalizedDistance) else { return false }
        let now = ContinuousClock.now
        if lastBeat == nil || now >= lastBeat!.advanced(by: .seconds(1 / frequency)) {
            lastBeat = now
            let deadline = ProcessInfo.processInfo.systemUptime + 0.04
            if audioEnabled { audioOutput.playPulse(at: deadline) }
            if hapticsEnabled { hapticOutput.pulse(at: deadline) }
        }
        return true
    }

    /// Silence stale tracking without ever treating elapsed time as arrival.
    private func startFreshnessWatch() {
        guard freshnessTask == nil else { return }
        freshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard self?.expireStaleGuidance(at: .now) == false else { return }
            }
        }
    }

    @discardableResult
    func expireStaleGuidance(at now: ContinuousClock.Instant) -> Bool {
        guard let receivedAt else { return true }
        guard receivedAt.duration(to: now) >= GuidanceArrivalHold.maximumSampleGap else { return false }
        stop()
        instructionText = "Guidance paused."
        return true
    }

    private func observeLifecycle() {
        #if os(iOS)
        guard observers.isEmpty else { return }
        for name in [UIApplication.willResignActiveNotification, AVAudioSession.interruptionNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
                .store(in: &observers)
        }
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable else { return }
                MainActor.assumeIsolated { self?.stop() }
            }
            .store(in: &observers)
        #endif
    }
}
