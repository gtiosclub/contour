//
//  DirectionalAudioEngine.swift
//  ContourFeedback
//
//  Created by Asutosh Mishra on 10/4/26.
//

import AVFoundation

@MainActor
final class DirectionalAudioEngine {

    // MARK: - Pitch mapping
    private struct PitchMapping {
        var minRate: Float = 0.75
        var maxRate: Float = 2.0
        func rate(for v: Float) -> Float { minRate * powf(maxRate / minRate, v) }
    }
    private var mapping = PitchMapping()

    // MARK: - Audio graph
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private lazy var buffer = Self.makeBuffer(format: format, harmonic: false)
    private var isWired = false

    // MARK: - State
    private var targetPan: Float = 0
    private var targetRate: Float = 0.75
    private var userVolume: Float = 0.5
    private var fadeTarget: Float = 0          // 1 while playing, 0 while stopped/fading out
    private var curPan: Float = 0
    private var curRate: Float = 0.75
    private var curGain: Float = 0
    private var wantsToPlay = false
    private var tickTask: Task<Void, Never>?
    private var configTask: Task<Void, Never>?

    init() {
        engine.attach(player)
        engine.attach(varispeed)
    }

    // MARK: - Public API (frozen Friday)
    func start() throws {
        wantsToPlay = true
        fadeTarget = 1
        guard !engine.isRunning else { return }   // idempotent
        try wireIfNeeded()
        try engine.start()
        player.stop()                              // clears anything queued, so no double-schedule
        curGain = 0
        player.volume = 0
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()                              // or: try player.playAudio() if Xcode warns
        startTicker()
        observeEngineConfigChanges()
    }

    func stop() {
        wantsToPlay = false
        fadeTarget = 0                             // ticker fades to silence
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !self.wantsToPlay else { return }  // user may have restarted
            self.player.stop()
            self.engine.stop()
            self.tickTask?.cancel(); self.tickTask = nil
        }
    }

    func setBeacon(pan: Float, proximity: Float) {
        if pan.isFinite { targetPan = min(max(pan, -1), 1) }
        if proximity.isFinite {
            targetRate = mapping.rate(for: min(max(proximity, 0), 1))
        }
    }

    func setVolume(_ volume: Float) {
        if volume.isFinite { userVolume = min(max(volume, 0), 1) }
    }

    /// Call from Nancy's AudioSessionEvent handler on route changes.
    func handleRouteChange() {
        guard wantsToPlay, !engine.isRunning else { return }
        try? start()
    }

    // MARK: - Internals
    private func wireIfNeeded() throws {
        guard !isWired else { return }
        try connect(player, to: varispeed)
        try connect(varispeed, to: engine.mainMixerNode)
        isWired = true
    }

    private func connect(_ a: AVAudioNode, to b: AVAudioNode) throws {
        if #available(iOS 27, *) {
            try engine.connectNode(a, to: b, format: format)
        } else {
            engine.connect(a, to: b, format: format)
        }
    }

    private func startTicker() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))   // ~60 Hz
            }
        }
    }

    private func tick() {
        let k: Float = 0.25                        // tune by ear
        curPan  += (targetPan  - curPan)  * k
        curRate += (targetRate - curRate) * k
        curGain += (userVolume * fadeTarget - curGain) * k
        player.pan = curPan
        varispeed.rate = curRate
        player.volume = curGain
    }

    private func observeEngineConfigChanges() {
        guard configTask == nil else { return }
        configTask = Task { @MainActor [weak self] in
            let name = Notification.Name.AVAudioEngineConfigurationChange
            for await _ in NotificationCenter.default.notifications(named: name) {
                self?.handleRouteChange()
            }
        }
    }

    private static func makeBuffer(format: AVAudioFormat, harmonic: Bool) -> AVAudioPCMBuffer {
        let n: AVAudioFrameCount = 4_800           // 100 cycles of 480 Hz at 48 kHz
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        let p = buf.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Float(i) / 48_000
            var s = sinf(2 * .pi * 480 * t)
            if harmonic { s = (s + 0.3 * sinf(2 * .pi * 960 * t)) / 1.3 }
            p[i] = s * 0.5
        }
        return buf
    }
}
