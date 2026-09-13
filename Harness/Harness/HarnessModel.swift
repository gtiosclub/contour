//
//  HarnessModel.swift
//  Harness
//
//  Holds the synthetic spatial state the sliders drive, and pushes it into the
//  injected FeedbackEngine.
//
//  COORDINATES: fingertip is in normalized panel space — (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. The sliders deliberately range past 0...1 so
//  you can push the finger off the panel, which is a real case guidance has to
//  handle. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
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

    // MARK: Wiring

    private let engine: any FeedbackEngine
    private var walk: Task<Void, Never>?

    /// Set while the auto-walk drives the sliders, so that moving them
    /// programmatically does not emit a second frame per step.
    private var isSuppressingEmit = false

    init(engine: any FeedbackEngine) {
        self.engine = engine
        self.targetID = MockSurfaceMaps.microwaveStartButton.id
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

        let frame = TrackingFrame(
            timestamp: Date(),
            fingertip: trackingQuality == .lost
                ? nil
                : PanelPoint(x: fingertipX, y: fingertipY),
            panel: MockTrackingSource().frame(atStep: 0).panel,
            trackingQuality: trackingQuality
        )
        send(MockGuidance.state(for: frame, target: target), note: "slider")
    }

    /// Fire one of the four outcome signals by hand.
    func fire(_ outcome: OutcomeSignal) {
        send(.outcome(outcome, at: Date()), note: "button")
    }

    /// Replay `MockTrackingSource`'s deterministic walk toward the current
    /// target, so Team 3 can feel a whole approach rather than scrub one.
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

    private func send(_ state: GuidanceState, note: String) {
        log.insert(LogEntry(state: state, note: note), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }

        let engine = engine
        Task { await engine.present(state) }
    }
}
