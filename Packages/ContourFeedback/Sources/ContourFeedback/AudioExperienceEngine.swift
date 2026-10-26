//  AudioExperienceEngine.swift
//  ContourFeedback — Experience prototype
//  Experience Subteam - Evan

import AVFoundation
import Foundation
import Observation

/// Independent proximity audio: a soft, fixed-pitch pluck repeats faster nearby.
/// No bundled sounds, system alert sounds, microphone, or third-party libraries.
/// Retain for the test session; stop on navigation, backgrounding, or mute.
@MainActor
@Observable
public final class AudioExperienceEngine {
    public private(set) var distance: Double?
    public private(set) var isRunning = false
    public private(set) var isPlayingSuccess = false
    public private(set) var lastError: String?

    public var frequencyHz: Double? {
        distance.flatMap { Self.frequency(for: $0) }
    }

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var tone: AVAudioPCMBuffer?
    @ObservationIgnored private var successTone: AVAudioPCMBuffer?
    @ObservationIgnored private var successID: UUID?
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    @ObservationIgnored private var lastPulse: ContinuousClock.Instant?

    public init() {}

    isolated deinit {
        pulseTask?.cancel()
        player.stop()
        audioEngine.stop()
    }

    /// Distance is in normalized panel units. d=0 → 6 Hz, d=0.5 → 3.5 Hz,
    /// d>=1 → 1 Hz. Invalid samples are silent rather than treated as arrival.
    public nonisolated static func frequency(for distance: Double) -> Double? {
        guard distance.isFinite, distance >= 0 else { return nil }
        let proximity = 1 - min(distance, 1)
        let eased = proximity * proximity * (3 - 2 * proximity)
        return 1 + 5 * eased
    }

    /// Starts its own beat loop unless externallyClocked is true, in which case
    /// the caller schedules notes with playPulse(at:). Repeated starts update
    /// distance without resetting playback. Setup failures are reported to the UI.
    public func start(distance: Double, externallyClocked: Bool = false) throws {
        if isPlayingSuccess { stop() }
        update(distance: distance)
        guard self.distance != nil, !isRunning else { return }
        lastError = nil
        do {
            try prepareToneIfNeeded()
            try startOutput()
            isRunning = true
            lastPulse = nil
            if !externallyClocked {
                pulseTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let shouldContinue = self?.tick(), shouldContinue else { return }
                        do {
                            try await Task.sleep(for: .milliseconds(10))
                        } catch {
                            return
                        }
                    }
                }
            }
        } catch {
            stop()
            lastError = error.localizedDescription
            throw error
        }
    }

    /// A valid update doesn't start stopped playback. Invalid or missing input
    /// cancels playback and removes queued notes immediately.
    public func update(distance: Double?) {
        guard let distance, Self.frequency(for: distance) != nil else {
            stop()
            return
        }
        self.distance = distance
    }

    /// Replaces proximity notes with a short ascending confirmation chime.
    /// Synthesized natively, not an undocumented system sound ID.
    public func playSuccess() throws {
        stop()
        lastError = nil
        do {
            try prepareToneIfNeeded()
            try prepareSuccessToneIfNeeded()
            try startOutput()
            guard let successTone else { throw AudioSetupError.bufferUnavailable }
            let id = UUID()
            successID = id
            isPlayingSuccess = true
            player.scheduleBuffer(successTone, atTime: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] in
                Task { @MainActor in
                    guard let self, self.successID == id else { return }
                    self.stop()
                }
            }
        } catch {
            stop()
            lastError = error.localizedDescription
            throw error
        }
    }

    public func stop() {
        successID = nil
        isPlayingSuccess = false
        isRunning = false
        pulseTask?.cancel()
        pulseTask = nil
        player.stop()
        audioEngine.stop()
        lastPulse = nil
        distance = nil
    }

    /// Schedule a note at a shared monotonic system-uptime time. When using
    /// externallyClocked playback, call once per beat from the shared scheduler.
    public func playPulse(at uptime: TimeInterval) {
        guard isRunning, uptime.isFinite, let tone else { return }
        guard audioEngine.isRunning, player.isPlaying else {
            stop()
            lastError = "Audio was interrupted. Press Start to resume."
            return
        }
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: max(uptime, ProcessInfo.processInfo.systemUptime)))
        player.scheduleBuffer(tone, at: when, options: [], completionHandler: nil)
    }

    private func tick() -> Bool {
        guard isRunning, let frequencyHz else { return false }
        let now = ContinuousClock.now
        if let lastPulse, now < lastPulse.advanced(by: .seconds(1 / frequencyHz)) {
            return true
        }
        lastPulse = now
        // Schedule a little ahead so audio and haptics can share one deadline.
        // Skip missed beats rather than enqueueing a catch-up burst.
        playPulse(at: ProcessInfo.processInfo.systemUptime + 0.04)
        return isRunning
    }

    private func startOutput() throws {
        #if os(iOS)
        // Guidance is deliberately audible in Silent Mode. Mix with other
        // audio (including VoiceOver) rather than taking exclusive output.
        // This prototype doesn't deactivate the shared session on stop:
        // the app's camera/speech may also own it.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        #endif
        audioEngine.prepare()
        try audioEngine.start()
        try player.playAudio()
    }

    private func prepareSuccessToneIfNeeded() throws {
        guard successTone == nil else { return }
        let sampleRate = 48_000.0
        let duration = 0.36
        let count = AVAudioFrameCount(sampleRate * duration)
        guard let format = tone?.format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let samples = buffer.floatChannelData?[0] else {
            throw AudioSetupError.bufferUnavailable
        }
        buffer.frameLength = count
        // A soft E5 → A5 interval, with gently overlapping decays. The second
        // note is deliberately longer so confirmation differs from proximity.
        let notes: [(onset: Double, frequency: Double, duration: Double)] = [
            (0, 660, 0.18), (0.12, 880, 0.24),
        ]
        for index in 0..<Int(count) {
            let time = Double(index) / sampleRate
            var sample = 0.0
            for note in notes {
                let t = time - note.onset
                guard t >= 0, t < note.duration else { continue }
                let attack = sin(min(t / 0.006, 1) * .pi / 2)
                let release = sin(min((note.duration - t) / 0.04, 1) * .pi / 2)
                let envelope = attack * attack * exp(-t / 0.09) * release * release
                let body = sin(2 * .pi * note.frequency * t)
                    + 0.12 * sin(4 * .pi * note.frequency * t) * exp(-t / 0.035)
                sample += 0.22 * envelope * body
            }
            samples[index] = Float(sample)
        }
        successTone = buffer
    }

    private func prepareToneIfNeeded() throws {
        guard tone == nil else { return }
        let sampleRate = 48_000.0
        let duration = 0.085
        let count = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let samples = buffer.floatChannelData?[0] else {
            throw AudioSetupError.bufferUnavailable
        }
        buffer.frameLength = count
        for index in 0..<Int(count) {
            let time = Double(index) / sampleRate
            // Smooth 5 ms attack, exponential body, and 20 ms release. A quiet
            // octave adds a woody pluck without noise, harsh clicks, or reverb.
            let attack = sin(min(time / 0.005, 1) * .pi / 2)
            let release = sin(min((duration - time) / 0.020, 1) * .pi / 2)
            let envelope = attack * attack * exp(-time / 0.028) * release * release
            let fundamental = sin(2 * .pi * 660 * time)
            let overtone = 0.16 * sin(2 * .pi * 1_320 * time) * exp(-time / 0.018)
            samples[index] = Float(0.24 * envelope * (fundamental + overtone))
        }
        if player.engine == nil { audioEngine.attach(player) }
        try audioEngine.connectNode(player, to: audioEngine.mainMixerNode, format: format)
        tone = buffer
    }

    private enum AudioSetupError: LocalizedError {
        case bufferUnavailable

        var errorDescription: String? {
            "Unable to create the proximity sound."
        }
    }
}
