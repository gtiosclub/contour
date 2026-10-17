//
//  HarnessModel.swift
//  Harness
//
//  Holds the synthetic spatial state the sliders drive, and pushes it into the
//  FeedbackEngine picked in the window: the printing mock, or the real
//  LiveFeedbackEngine with a choice of guidance model and channels.
//
//  Switching engine, model or channel mid-run stops the old engine first, so
//  nothing is left buzzing or sounding, then hands the new one the current
//  frame so guidance carries straight on.
//
//  COORDINATES: fingertip is in normalized panel space — (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. The sliders deliberately range past 0...1 so
//  you can push the finger off the panel, which is a real case guidance has to
//  handle. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import Observation

@MainActor
@Observable
final class HarnessModel {

    // MARK: Synthetic state

    /// Fingertip x. Ranges past the panel edges on purpose.
    var fingertipX: Double = 0.12 { didSet { emit() } }

    /// Fingertip y. Larger is **lower** on the panel.
    var fingertipY: Double = 0.14 { didSet { emit() } }

    /// What the tracker claims about this frame. `.lost` drops the fingertip.
    var trackingQuality: TrackingQuality = .good { didSet { emit() } }

    /// Which control the user is being guided to.
    var targetID: SurfaceMap.Button.ID { didSet { emit() } }

    /// The canned panel. Fixed — this rig is about feedback, not detection.
    let map = MockSurfaceMaps.microwave

    /// What has been handed to the engine, newest first.
    private(set) var log: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let state: GuidanceState
        let note: String
    }

    // MARK: Which engine

    /// The engines the picker offers.
    enum EngineChoice: String, CaseIterable, Identifiable {
        /// `PrintingFeedbackEngine`: logs each state to the console. Feels like nothing.
        case printing
        /// `LiveFeedbackEngine`: the real haptics, tone, earcons and speech.
        case live

        var id: Self { self }

        var title: String {
            switch self {
            case .printing: "Printing mock"
            case .live: "Live engine"
            }
        }
    }

    /// Which engine the frames go to.
    var engineChoice: EngineChoice { didSet { if engineChoice != oldValue { replaceEngine() } } }

    /// The live engine's guidance model.
    var modelKind: GuidanceModelKind { didSet { if modelKind != oldValue { replaceEngine() } } }

    /// The live engine's directional tone and earcons. These work on a Mac.
    var audioOn: Bool { didSet { if audioOn != oldValue { replaceEngine() } } }

    /// The live engine's spoken outcome lines. These work on a Mac.
    var speechOn: Bool { didSet { if speechOn != oldValue { replaceEngine() } } }

    /// The live engine's directional haptic hint (#119). Haptic, so silent on a Mac.
    var hintOn: Bool { didSet { if hintOn != oldValue { replaceEngine() } } }

    /// Whether the live-engine controls mean anything right now.
    var isLive: Bool { engineChoice == .live }

    // MARK: Wiring

    private var engine: any FeedbackEngine
    private var walk: Task<Void, Never>?

    /// Set while the auto-walk drives the sliders, so that moving them
    /// programmatically does not emit a second frame per step.
    private var isSuppressingEmit = false

    /// The last engine swap, so frames sent after it wait for the old engine
    /// to be silenced before reaching the new one.
    private var handover: Task<Void, Never>?

    /// Starts with `engine`. The pickers take over from there; a
    /// `LiveFeedbackEngine` passed in sets them to its model and channels.
    init(engine: any FeedbackEngine) {
        self.engine = engine
        self.targetID = MockSurfaceMaps.microwaveStartButton.id
        if let live = engine as? LiveFeedbackEngine {
            engineChoice = .live
            modelKind = live.model
            audioOn = live.playsAudio
            speechOn = live.speaks
            hintOn = live.hintsDirection
        } else {
            engineChoice = .printing
            modelKind = ChosenGuidanceModel.current
            audioOn = true
            speechOn = true
            hintOn = false
        }
    }

    var target: SurfaceMap.Button {
        map.buttons.first { $0.id == targetID } ?? MockSurfaceMaps.microwaveStartButton
    }

    /// Whether the auto-walk is running.
    var isWalking: Bool { walk != nil }

    // MARK: Emitting

    /// Build a frame from the current slider state and send it through.
    func emit() {
        guard !isSuppressingEmit else { return }
        send(currentState(), note: "slider")
    }

    /// Fire one of the four outcome signals by hand.
    func fire(_ outcome: OutcomeSignal) {
        send(.outcome(outcome, at: Date()), note: "button")
    }

    /// Silence the live engine and forget its session, as if guidance ended.
    /// The next slider move starts a fresh session.
    func silence() {
        walk?.cancel()
        walk = nil
        let engine = engine
        let previous = handover
        handover = Task {
            await previous?.value
            if let live = engine as? LiveFeedbackEngine { await live.stop() }
        }
    }

    /// Replay `MockTrackingSource`'s deterministic walk toward the current
    /// target, so Experience can feel a whole approach rather than scrub one.
    func toggleWalk() {
        if let walk {
            walk.cancel()
            self.walk = nil
            return
        }

        let source = MockTrackingSource(
            start: PanelPoint(x: fingertipX, y: fingertipY),
            target: target.bounds.center,
            steps: 60,
            interval: .milliseconds(50),
            baseTimestamp: Date()
        )

        walk = Task { [weak self] in
            for await frame in source.frames() {
                guard let self, !Task.isCancelled else { return }
                self.isSuppressingEmit = true
                self.fingertipX = frame.fingertip?.x ?? self.fingertipX
                self.fingertipY = frame.fingertip?.y ?? self.fingertipY
                self.isSuppressingEmit = false
                self.send(
                    MockGuidance.state(for: frame, target: self.target),
                    note: "walk"
                )
            }
            self?.walk = nil
        }
    }

    // MARK: Private

    private func currentState() -> GuidanceState {
        let frame = TrackingFrame(
            timestamp: Date(),
            fingertip: trackingQuality == .lost
                ? nil
                : PanelPoint(x: fingertipX, y: fingertipY),
            panel: MockTrackingSource().frame(atStep: 0).panel,
            trackingQuality: trackingQuality
        )
        return MockGuidance.state(for: frame, target: target)
    }

    private func makeEngine() -> any FeedbackEngine {
        switch engineChoice {
        case .printing:
            PrintingFeedbackEngine()
        case .live:
            LiveFeedbackEngine(model: modelKind, audio: audioOn, speech: speechOn, directionalHint: hintOn)
        }
    }

    /// Stop the old engine, then give the new one the current frame. Frames
    /// sent meanwhile queue behind the handover, so the old engine's stop can
    /// never silence the new engine's first frames.
    private func replaceEngine() {
        let old = engine
        let new = makeEngine()
        engine = new
        let previous = handover
        let current = currentState()
        let resume = !isWalking
        handover = Task {
            await previous?.value
            if let live = old as? LiveFeedbackEngine { await live.stop() }
            if resume { await new.present(current) }
        }
        if resume {
            log.insert(LogEntry(state: current, note: "switch"), at: 0)
        }
    }

    private func send(_ state: GuidanceState, note: String) {
        log.insert(LogEntry(state: state, note: note), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }

        let engine = engine
        if let handover {
            Task {
                await handover.value
                await engine.present(state)
            }
        } else {
            Task { await engine.present(state) }
        }
    }
}
