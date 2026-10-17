//
//  ToneEngine.swift
//  ContourFeedback — Experience / Audio & Speech
//
//  The one AVAudioEngine graph behind every tone Contour plays. DirectionalAudio
//  (guidance) and DirectionalAudioEngine (the debug screen's API from #11) used
//  to build the same graph twice; both now drive one of these.
//
//  GRAPH
//      loop player ──▶ varispeed ──▶ pan mixer ──▶ main mixer ──▶ output
//      earcon player ─────────────────────────────▲
//
//  - The loop player repeats LoopTone's buffer forever. Pitch is the varispeed
//    rate: 480 Hz × rate.
//  - Pan and level live on the pan mixer's input to the main mixer, not on the
//    player. AVAudioMixing settings only reach a mixer the node feeds directly;
//    an effect node in between (the varispeed) swallows them, so `player.pan`
//    did nothing. Everything is MONO up to the main mixer, or pan does nothing.
//  - Earcons (the outcome sounds) are rendered once into a buffer each and
//    played on their own node, centred, so they never fight the tone's pan.
//  - Values never jump. Callers set targets; a ~60 Hz tick moves the live values
//    a quarter of the way there each frame, so fast changes don't zipper and
//    starts and stops fade instead of clicking.
//
//  RECOVERY
//  The engine stops itself on a route change (headphones in or out) and on an
//  interruption. The tone listens to AudioSessionConfig.events() and restarts if
//  someone still wants it. It never sets the session category. A caller that
//  keeps retargeting (guidance, at camera rate) also restarts it on its next call.
//

import AVFoundation
import Foundation

// MARK: - The loop buffer (internal so tests can inspect it)

enum LoopTone {
    static let sampleRate = 48_000.0
    static let frequency = 480.0                        // exactly 100 samples per cycle
    static let frameCount: AVAudioFrameCount = 4_800    // exactly 100 cycles, so the loop point is seamless

    /// The second harmonic's level relative to the fundamental. A pure sine is
    /// hard to place left or right; a little 2× energy makes the pan easier to hear.
    static let harmonicLevel = 0.3

    /// One sample of the loop. Peak stays at 0.5 with or without the harmonic.
    static func sample(at index: Int, harmonic: Bool) -> Double {
        let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
        var value = sin(phase)
        if harmonic {
            value = (value + harmonicLevel * sin(2 * phase)) / (1 + harmonicLevel)
        }
        return 0.5 * value
    }

    static func makeBuffer(harmonic: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!  // MONO, or pan does nothing
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sample(at: index, harmonic: harmonic))
        }
        return buffer
    }
}

// MARK: - The engine

@MainActor
final class ToneEngine {

    /// The guidance tone. One for the app, because DirectionalAudio is a value
    /// type and two LiveFeedbackEngines must never play two tones.
    nonisolated static let guidance = ToneEngine(harmonic: true)

    /// Pan, varispeed rate and gain: what the tick moves toward.
    struct Mix: Equatable {
        var pan: Float
        var rate: Float
        var gain: Float
    }

    /// Fraction of the remaining distance covered per tick. Tune by ear.
    static let smoothing: Float = 0.25
    static let tickInterval = Duration.milliseconds(16)   // ~60 Hz
    /// AVAudioUnitVarispeed's range.
    static let rateRange: ClosedRange<Float> = 0.25...4
    /// Below this the fade-out is inaudible and the engine can stop.
    static let silence: Float = 0.002

    private let harmonic: Bool

    /// Where the tone is heading.
    private(set) var target = Mix(pan: 0, rate: 1, gain: 1)
    /// What is playing right now.
    private(set) var current = Mix(pan: 0, rate: 1, gain: 0)
    /// Master level, `0...1`. The debug screen's volume slider.
    private(set) var volume: Float = 1
    /// Speech ducking, `0...1`. 1 is no ducking.
    private(set) var duck: Float = 1
    /// Whether a caller has asked for the tone and not yet asked it to stop.
    private(set) var wantsTone = false

    private var graph: Graph?
    private var ticker: Task<Void, Never>?
    private var sessionEvents: Task<Void, Never>?
    private var earconBuffers: [Earcon: AVAudioPCMBuffer] = [:]
    /// When the last earcon finishes; the engine stays up until then.
    private var earconEndsAt: ContinuousClock.Instant?

    /// Built lazily on first start, so constructing the package's types stays
    /// cheap and nothing touches audio hardware until something plays.
    private struct Graph {
        let engine = AVAudioEngine()
        let loop = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        let panMixer = AVAudioMixerNode()
        let earcons = AVAudioPlayerNode()
        let buffer: AVAudioPCMBuffer
    }

    nonisolated init(harmonic: Bool) {
        self.harmonic = harmonic
    }

    // MARK: Driving it

    /// Set where the tone is heading. Non-finite values are ignored and the rest
    /// are clamped. Starts nothing.
    func retarget(pan: Float? = nil, rate: Float? = nil, gain: Float? = nil) {
        if let pan, pan.isFinite { target.pan = min(max(pan, -1), 1) }
        if let rate, rate.isFinite { target.rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
        if let gain, gain.isFinite { target.gain = min(max(gain, 0), 1) }
    }

    /// Head for `cue` and make sure the tone is playing. Cheap enough to call on
    /// every guidance frame. A cue containing a non-finite value is ignored.
    func render(_ cue: AudioCue) {
        guard cue.pan.isFinite, cue.pitch.isFinite, cue.gain.isFinite else { return }
        retarget(pan: Float(cue.pan), rate: Float(cue.pitch / LoopTone.frequency), gain: Float(cue.gain))
        try? start()   // wantsTone stays true on failure, so the next call retries
    }

    func setVolume(_ value: Float) {
        if value.isFinite { volume = min(max(value, 0), 1) }
    }

    func setDuck(_ value: Float) {
        if value.isFinite { duck = min(max(value, 0), 1) }
    }

    /// Start the tone, or keep it going. A cold start fades in from silence.
    func start() throws {
        wantsTone = true
        try ensureRunning()
        startTicker()
    }

    /// Fade out, then halt the engine. Safe to call when idle.
    func stop() {
        wantsTone = false
    }

    /// Play `earcon` once, centred, cutting off any earcon still playing. Does
    /// not touch the tone: an outcome stops that separately.
    func play(_ earcon: Earcon) {
        do {
            try ensureRunning()
        } catch {
            return
        }
        guard let graph, let buffer = earconBuffer(for: earcon, format: graph.buffer.format) else { return }
        graph.earcons.volume = volume
        graph.earcons.scheduleBuffer(buffer, at: nil, options: .interrupts)
        graph.earcons.play()
        earconEndsAt = ContinuousClock.now + earcon.duration + .milliseconds(100)
        startTicker()   // keeps the engine up until the earcon is done, then halts it
    }

    var isRunning: Bool { graph?.engine.isRunning ?? false }

    /// The gain the tick is heading for: silence unless someone wants the tone.
    var targetLevel: Float {
        Self.level(gain: target.gain, volume: volume, duck: duck, wanted: wantsTone)
    }

    /// The tone's output level: the cue's gain, scaled by the master volume and
    /// the speech duck, or silence when nobody wants it. Pure, for tests.
    nonisolated static func level(gain: Float, volume: Float, duck: Float, wanted: Bool) -> Float {
        wanted ? gain * volume * duck : 0
    }

    /// React to the shared audio session. Internal so tests and the debug API
    /// can drive it.
    func handle(_ event: AudioSessionConfig.Event) {
        switch event {
        case .interruptionBegan:
            break   // the system has already paused the engine
        case .interruptionEnded(let shouldResume):
            if shouldResume { restartIfWanted() }
        case .routeChanged:
            restartIfWanted()
            // The engine can stop a moment after the notification. Look again.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.restartIfWanted()
            }
        }
    }

    func restartIfWanted() {
        guard wantsTone, !isRunning else { return }
        try? start()
    }

    // MARK: Internals

    private func ensureRunning() throws {
        let graph = try requireGraph()
        guard !graph.engine.isRunning else { return }
        try graph.engine.start()   // the session category is NOT set here; AudioSessionConfig owns it
        current = Mix(pan: target.pan, rate: target.rate, gain: 0)   // start at the target, fade in
        apply(to: graph)
        graph.loop.stop()          // clear anything queued so we never double-schedule
        graph.loop.scheduleBuffer(graph.buffer, at: nil, options: .loops)
        graph.loop.play()
        listenForSessionEvents()
    }

    private func requireGraph() throws -> Graph {
        if let graph { return graph }
        let graph = Graph(buffer: LoopTone.makeBuffer(harmonic: harmonic))
        let engine = graph.engine
        let format = graph.buffer.format
        engine.attach(graph.loop)
        engine.attach(graph.varispeed)
        engine.attach(graph.panMixer)
        engine.attach(graph.earcons)
        try Self.connect(graph.loop, to: graph.varispeed, format: format, in: engine)
        try Self.connect(graph.varispeed, to: graph.panMixer, format: format, in: engine)
        try Self.connect(graph.panMixer, to: engine.mainMixerNode, format: format, in: engine)
        try Self.connect(graph.earcons, to: engine.mainMixerNode, format: format, in: engine)
        self.graph = graph
        return graph
    }

    private static func connect(
        _ source: AVAudioNode,
        to destination: AVAudioNode,
        format: AVAudioFormat,
        in engine: AVAudioEngine
    ) throws {
        // connectNode(_:to:format:) is the throwing iOS 27 replacement. The
        // compiler check keeps this building on the Xcode 26 toolchain too.
        #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
            try engine.connectNode(source, to: destination, format: format)
            return
        }
        #endif
        engine.connect(source, to: destination, format: format)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Moves current values a fraction of the way to their targets: no zipper
    /// noise on fast changes, no click on start or stop.
    private func tick() {
        guard let graph else { return }
        let k = Self.smoothing
        current.pan += (target.pan - current.pan) * k
        current.rate += (target.rate - current.rate) * k
        current.gain += (targetLevel - current.gain) * k
        apply(to: graph)
        if !wantsTone && current.gain < Self.silence && !isPlayingEarcon { halt(graph) }
    }

    private var isPlayingEarcon: Bool {
        guard let earconEndsAt else { return false }
        return ContinuousClock.now < earconEndsAt
    }

    private func earconBuffer(for earcon: Earcon, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if let cached = earconBuffers[earcon] { return cached }
        let samples = earcon.samples(sampleRate: format.sampleRate)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channel[index] = sample }
        earconBuffers[earcon] = buffer
        return buffer
    }

    private func apply(to graph: Graph) {
        graph.panMixer.pan = current.pan
        graph.panMixer.volume = current.gain
        graph.varispeed.rate = current.rate
    }

    private func halt(_ graph: Graph) {
        graph.loop.stop()
        graph.earcons.stop()
        earconEndsAt = nil
        graph.engine.stop()
        ticker?.cancel()
        ticker = nil
        current.gain = 0
    }

    private func listenForSessionEvents() {
        guard sessionEvents == nil else { return }
        sessionEvents = Task { [weak self] in
            for await event in AudioSessionConfig.events() {
                guard let self else { return }   // the tone is gone: stop listening
                self.handle(event)
            }
        }
    }
}
