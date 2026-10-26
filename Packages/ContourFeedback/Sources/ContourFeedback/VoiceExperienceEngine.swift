//  VoiceExperienceEngine.swift
//  ContourFeedback — Experience prototype
//  Experience Subteam - Evan

import AVFoundation
import Foundation
import Observation

/// Semantic input from the axis-locking guidance model; never derives a second
/// competing direction from distance. All speech is bundled, whole-phrase audio.
public enum ExperienceVoiceGuidance: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case left, right, up, down
    }

    case direction(Direction, near: Bool)
    case slowly, arrived, paused
}

enum ExperienceVoiceCue: String, CaseIterable, Sendable {
    case moveLeft = "move_left", moveRight = "move_right"
    case moveUp = "move_up", moveDown = "move_down"
    case nowLeft = "now_left", nowRight = "now_right"
    case nowUp = "now_up", nowDown = "now_down"
    case nearLeft = "near_left", nearRight = "near_right"
    case nearUp = "near_up", nearDown = "near_down"
    case further = "a_little_further", slowly = "move_slowly"
    case stop, reached = "target_reached", paused = "guidance_paused"

    static func direction(_ direction: ExperienceVoiceGuidance.Direction,
                          near: Bool, changed: Bool = false) -> Self {
        switch (direction, changed, near) {
        case (.left, true, _): .nowLeft
        case (.right, true, _): .nowRight
        case (.up, true, _): .nowUp
        case (.down, true, _): .nowDown
        case (.left, false, true): .nearLeft
        case (.right, false, true): .nearRight
        case (.up, false, true): .nearUp
        case (.down, false, true): .nearDown
        case (.left, false, false): .moveLeft
        case (.right, false, false): .moveRight
        case (.up, false, false): .moveUp
        case (.down, false, false): .moveDown
        }
    }
}

/// Clock-injected policy so stale-direction cancellation and reminder timing can
/// be tested without opening an audio device. There is no FIFO of instructions.
struct ExperienceVoicePolicy {
    private var previous: ExperienceVoiceGuidance?
    private var lastTime: TimeInterval?
    private var lastCueTime = 0.0
    private var closestDistance: Double?
    private var previousDistance: Double?

    mutating func update(_ guidance: ExperienceVoiceGuidance, distance: Double,
                         at time: TimeInterval, isSpeaking: Bool) -> [ExperienceVoiceCue]? {
        guard time.isFinite else { return nil }
        guard lastTime.map({ time > $0 }) ?? true else { return nil }
        lastTime = time
        let current: ExperienceVoiceGuidance = distance.isFinite && distance >= 0 ? guidance : .paused
        let movingAway = previousDistance.map { distance > $0 } ?? false
        if distance.isFinite, distance >= 0 {
            previousDistance = distance
            closestDistance = min(closestDistance ?? distance, distance)
        } else {
            previousDistance = nil
            closestDistance = nil
        }
        let old = previous
        var cues: [ExperienceVoiceCue]?
        if current != old {
            switch current {
            case let .direction(direction, near):
                let changed: Bool
                if case let .direction(oldDirection, _) = old { changed = oldDirection != direction }
                else { changed = false }
                // Defer a wording-only change until the current sentence ends.
                // Direction changes, arrival and loss always interrupt immediately.
                if !changed, case .direction = old, isSpeaking { return nil }
                cues = [.direction(direction, near: near, changed: changed)]
            case .slowly: cues = [.slowly]
            case .arrived: cues = [.stop, .reached]
            case .paused: cues = [.paused]
            }
        } else if !isSpeaking, case let .direction(direction, near) = current {
            let elapsed = time - lastCueTime
            let retreat = distance - (closestDistance ?? distance)
            // Remind only while moving away, after a meaningful retreat. No
            // timer-only repeats while stationary or approaching, even slowly.
            // Reset the baseline after each cue so an old retreat cannot cause
            // repeated reminders; small positional noise is ignored.
            if elapsed >= 2, movingAway, retreat >= 0.025 {
                cues = [.direction(direction, near: near)]
            }
        }
        previous = current
        if cues != nil {
            lastCueTime = time
            closestDistance = distance.isFinite && distance >= 0 ? distance : nil
        }
        return cues
    }
}

/// Retain for the test session. The caller stops this engine on mute, navigation,
/// backgrounding, interruption, and headphone disconnection.
@MainActor
@Observable
public final class VoiceExperienceEngine {
    public private(set) var isRunning = false
    public private(set) var isSpeaking = false
    public private(set) var lastError: String?

    @ObservationIgnored private var policy = ExperienceVoicePolicy()
    @ObservationIgnored private var players: [ExperienceVoiceCue: AVAudioPlayer] = [:]
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var playbackID: UUID?

    public init() {}

    isolated deinit {
        playbackTask?.cancel()
        for player in players.values { player.stop() }
    }

    public func start() throws {
        guard !isRunning else { return }
        lastError = nil
        do {
            // Preload the small vocabulary once; direction changes need no I/O.
            for cue in ExperienceVoiceCue.allCases where players[cue] == nil {
                guard let url = Self.resourceURL(for: cue) else {
                    throw VoiceError.missingClip(cue.rawValue)
                }
                let player = try AVAudioPlayer(contentsOf: url)
                guard player.prepareToPlay() else { throw VoiceError.playbackFailed }
                players[cue] = player
            }
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            #endif
            policy = ExperienceVoicePolicy()
            isRunning = true
        } catch {
            stop()
            lastError = error.localizedDescription
            throw error
        }
    }

    public func update(_ guidance: ExperienceVoiceGuidance, distance: Double, at time: TimeInterval) {
        guard isRunning,
              let cues = policy.update(guidance, distance: distance, at: time, isSpeaking: isSpeaking) else { return }
        cancelPlayback()
        let id = UUID()
        playbackID = id
        isSpeaking = true
        // Only arrival has two clips: Stop, then Target reached. Any new state
        // cancels the entire sequence, including its not-yet-played second clip.
        playbackTask = Task { @MainActor [weak self] in
            for cue in cues {
                guard !Task.isCancelled, let player = self?.players[cue] else { return }
                player.currentTime = 0
                guard player.play() else {
                    self?.failPlayback(id: id)
                    return
                }
                while player.isPlaying {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    guard self?.playbackID == id else { return }
                }
            }
            guard let self, self.playbackID == id else { return }
            self.isSpeaking = false
            self.playbackTask = nil
            self.playbackID = nil
        }
    }

    public func stop() {
        cancelPlayback()
        isRunning = false
        policy = ExperienceVoicePolicy()
    }

    static func resourceURL(for cue: ExperienceVoiceCue) -> URL? {
        Bundle.module.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "VoicePrompts")
    }

    private func cancelPlayback() {
        playbackID = nil
        playbackTask?.cancel()
        playbackTask = nil
        for player in players.values { player.stop() }
        isSpeaking = false
    }

    private func failPlayback(id: UUID) {
        guard playbackID == id else { return }
        stop()
        lastError = VoiceError.playbackFailed.localizedDescription
    }

    private enum VoiceError: LocalizedError {
        case missingClip(String), playbackFailed
        var errorDescription: String? {
            switch self {
            case let .missingClip(name): "Missing voice recording: \(name)."
            case .playbackFailed: "Unable to play voice guidance. Press Start to retry."
            }
        }
    }
}
