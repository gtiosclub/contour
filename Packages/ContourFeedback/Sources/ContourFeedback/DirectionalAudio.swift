//
//  DirectionalAudio.swift
//  ContourFeedback — Experience / Audio & Speech
//
//  Weeks 2–3 deliverable: "Prototype directional audio."
//
//  Which way, as something you hear.
//
//  ⚠️ THE AXIS TRAP
//  `direction.dy` is POSITIVE DOWNWARD. A direction of (0, -1) means "move the
//  finger UP the panel". If you map dy straight onto pitch without thinking
//  about it, higher pitch will mean "move down" and every user will go the wrong
//  way — and they cannot see that they are going the wrong way.
//  See Packages/ContourCore/COORDINATES.md.
//
import AVFoundation
import ContourCore
import Foundation

public struct AudioCue: Hashable, Sendable {
    public var pan: Double
    public var pitch: Double
    public var gain: Double
    public init(pan: Double, pitch: Double, gain: Double) {
        self.pan = pan; self.pitch = pitch; self.gain = gain
    }
}

public struct DirectionalAudio: Sendable {

    /// Pitch range in Hz (matches the 0.75...2.0 varispeed range on a 480 Hz tone).
    public static let lowPitch: Double = 360    // target is straight DOWN
    public static let highPitch: Double = 960   // target is straight UP

    /// Distance at (or beyond) which the cue is at its quietest, in the same units as
    /// `GuidanceState`'s distance. ⚠️ Tune to your panel's units.
    public let farDistance: Double
    /// Floor so a far target is still audible; the user can't see that it's silent.
    public let minimumGain: Double

    public init(farDistance: Double = 300, minimumGain: Double = 0.2) {
        self.farDistance = farDistance
        self.minimumGain = minimumGain
    }

    // MARK: - Pure mapping (unit-tested)

    /// Direction only: pan from dx, pitch from dy, gain 1.0 because a unit vector has no distance.
    public func cue(for direction: PanelVector) -> AudioCue {
        let dx = Double(direction.dx)
        let dy = Double(direction.dy)

        let pan = dx.isFinite ? min(max(dx, -1), 1) : 0

        // THE AXIS TRAP: +dy is DOWN, so "up" is -dy. Negate before mapping to pitch.
        let up = dy.isFinite ? min(max(-dy, -1), 1) : 0     // -1 down ... +1 up
        let t = (up + 1) / 2                                 // 0 down ... 1 up
        let pitch = Self.lowPitch * pow(Self.highPitch / Self.lowPitch, t)  // equal steps = equal musical intervals

        return AudioCue(pan: pan, pitch: pitch, gain: 1)
    }

    /// Direction plus distance: closer is louder.
    public func cue(for direction: PanelVector, distance: Double) -> AudioCue {
        var cue = self.cue(for: direction)
        cue.gain = gain(forDistance: distance)
        return cue
    }

    public func gain(forDistance distance: Double) -> Double {
        guard distance.isFinite else { return minimumGain }
        let closeness = 1 - min(max(distance / farDistance, 0), 1)   // 1 at the target, 0 when far
        return minimumGain + (1 - minimumGain) * closeness
    }

    // MARK: - Rendering

    /// Retargets the tone and returns. Cheap enough to call on every guidance update.
    public func play(for state: GuidanceState) async {
        guard let input = state.audioInput else {
            await ToneRenderer.shared.stop()
            return
        }
        await ToneRenderer.shared.render(cue(for: input.direction, distance: input.distance))
    }

    /// Fades out and halts. Safe to call when idle.
    public func stop() async {
        await ToneRenderer.shared.stop()
    }
}

// ⚠️ ADAPTER: the only place that depends on GuidanceState's shape. I assumed a struct
// with `direction` and `distance`. If it's an enum (.guiding / .arrived / .lost), switch
// on it here and return nil for the cases that should be silent.
private extension GuidanceState {
    var audioInput: (direction: PanelVector, distance: Double)? {
        (direction, Double(distance))
    }
}

// MARK: - The loop buffer (internal so tests can inspect it)

enum LoopTone {
    static let sampleRate = 48_000.0
    static let frequency = 480.0        // exactly 100 samples per cycle
    static let frameCount: AVAudioFrameCount = 4_800   // exactly 100 cycles, so the loop point is seamless

    static func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!  // MONO, or pan does nothing
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            samples[i] = 0.5 * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        return buffer
    }
}

// MARK: - Engine (one shared instance, since DirectionalAudio itself is a stateless struct)

private actor ToneRenderer {
    static let shared = ToneRenderer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let format: AVAudioFormat
    private let buffer: AVAudioPCMBuffer

    private var targetPan: Float = 0
    private var targetRate: Float = 1
    private var targetGain: Float = 0
    private var curPan: Float = 0
    private var curRate: Float = 1
    private var curGain: Float = 0
    private var wantsToPlay = false
    private var isWired = false
    private var tickTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        buffer = LoopTone.makeBuffer()
        format = buffer.format
        engine.attach(player)
        engine.attach(varispeed)
    }

    func render(_ cue: AudioCue) {
        guard cue.pan.isFinite, cue.pitch.isFinite, cue.gain.isFinite else { return }
        targetPan = Float(min(max(cue.pan, -1), 1))
        targetRate = Float(min(max(cue.pitch / LoopTone.frequency, 0.25), 4))  // varispeed range
        targetGain = Float(min(max(cue.gain, 0), 1))
        wantsToPlay = true
        startIfNeeded()
    }

    func stop() {
        wantsToPlay = false   // tick() fades to silence, then halts the engine
    }

    private func startIfNeeded() {
        if engine.isRunning { startTicker(); return }
        do {
            try wireIfNeeded()
            try engine.start()   // session category is NOT set here; Nancy's AudioSessionConfig owns it
        } catch {
            return               // wantsToPlay stays true, so the next render() retries
        }
        curPan = targetPan; curRate = targetRate; curGain = 0   // start at the target, fade in
        apply()
        player.stop()            // clear anything queued so we never double-schedule
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()            // if Xcode warns on iOS 27: try player.playAudio()
        startTicker()
        installObserver()
    }

    private func wireIfNeeded() throws {
        guard !isWired else { return }
        try connect(player, to: varispeed)
        try connect(varispeed, to: engine.mainMixerNode)
        isWired = true
    }

    private func connect(_ a: AVAudioNode, to b: AVAudioNode) throws {
        if #available(iOS 27, macOS 27, *) {
            try engine.connectNode(a, to: b, format: format)
        } else {
            engine.connect(a, to: b, format: format)
        }
    }

    private func startTicker() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(16))   // ~60 Hz
            }
        }
    }

    /// Moves current values a fraction of the way to their targets: no zipper noise on fast changes.
    private func tick() {
        let k: Float = 0.25   // tune by ear
        curPan += (targetPan - curPan) * k
        curRate += (targetRate - curRate) * k
        curGain += ((wantsToPlay ? targetGain : 0) - curGain) * k
        apply()
        if !wantsToPlay && curGain < 0.002 { halt() }
    }

    private func apply() {
        player.pan = curPan
        varispeed.rate = curRate
        player.volume = curGain
    }

    private func halt() {
        player.stop()
        engine.stop()
        tickTask?.cancel()
        tickTask = nil
        curGain = 0
    }

    /// Headphone plug/unplug stops the engine itself; restart if we still want sound.
    private func installObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.restartIfNeeded() }
        }
    }

    private func restartIfNeeded() {
        guard wantsToPlay, !engine.isRunning else { return }
        startIfNeeded()
    }
}
