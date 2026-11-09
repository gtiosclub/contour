//
//  TraceReplayTests.swift
//  Tracking
//
//  Synthetic traces built from HybridScene, marked synthetic in their notes.
//  The expectations come from the scene's design and the policy's documented
//  behaviour, not from a first replay of the same trace.
//

import Foundation
import Testing
import simd
@testable import Tracking

/// Builds a trace frame by frame, the way a recorder would see the scene.
private struct SyntheticRecording {
    static let firstReference = UUID(uuidString: "5A1C7E3B-9D2F-4B6A-8E1C-3F7A9B2D4E60")!

    var frames: [TraceFrame] = []
    var position: SIMD3<Float> = .zero
    var elapsed: TimeInterval = 0
    var session = HybridScene.session
    var reference: UUID? = firstReference
    let interval: TimeInterval = 0.15
    let planes = [HybridScene.surface(at: 0.5)]

    private mutating func record(visual: (WorldCameraSnapshot) throws -> PanelObservation,
                                 moving offset: SIMD3<Float>) rethrows {
        position += offset
        elapsed += interval
        let world = HybridScene.camera(at: position, planes: planes, session: session)
        let observation = try visual(world)
        frames.append(TraceFrame(index: frames.count, timestamp: observation.timestamp, orientation: .right,
                                 referenceID: reference, visual: observation, world: world))
    }

    /// The panel is in view and the visual tracker finds it.
    mutating func seen(_ count: Int = 1, moving offset: SIMD3<Float> = HybridScene.sideways) throws {
        for _ in 0..<count {
            let at = elapsed + interval
            try record(visual: { try HybridScene.seen(from: $0, at: at) }, moving: offset)
        }
    }

    /// The visual tracker reports loss; the world keeps tracking.
    mutating func lost(_ count: Int, moving offset: SIMD3<Float> = .zero) {
        for _ in 0..<count {
            let at = HybridScene.start.addingTimeInterval(elapsed + interval)
            record(visual: { _ in .lost(.notFound, at: at) }, moving: offset)
        }
    }

    func trace() -> CalibrationTrace {
        CalibrationTrace(
            notes: .init(synthetic: true, device: "none (HybridScene)", system: "none",
                         conditions: "synthetic 20 x 15 cm panel at 0.5 m", operatorNotes: "",
                         expectedEvents: []),
            sampling: .init(framesOffered: frames.count, framesDropped: 0),
            frames: frames)
    }
}

private func sources(_ replay: TraceReplay, _ range: ClosedRange<Int>) -> Set<HybridTrackingDiagnostics.Source> {
    Set(replay.steps.filter { range.contains($0.index) }.map(\.source))
}

private func resets(_ replay: TraceReplay) -> [TraceReplay.Event] {
    replay.events.filter { if case .reset = $0.change { true } else { false } }
}

@Suite("Calibration trace replay")
struct TraceReplayTests {
    /// The issue's example: sideways calibration, visual loss, return.
    /// HybridScene's ten 1 cm views are designed to clear the readiness gates;
    /// the policy documents projecting the model while the panel is out of sight.
    @Test func calibrateLoseAndRecover() throws {
        var recording = SyntheticRecording()
        try recording.seen(10)       // frames 0...9: 9 cm sideways in 1.35 s
        recording.lost(4)            // frames 10...13: covered for 0.6 s
        try recording.seen(2)        // frames 14...15: back in view

        let replay = try TraceReplay(recording.trace())

        let ready = replay.events.filter { $0.change == .calibrationReady(true) }
        #expect(ready.count == 1)
        #expect(ready.first.map { $0.index <= 9 } == true, "ready during the sideways movement")
        #expect(sources(replay, 10...13) == [.world], "AR prediction while the panel is hidden")
        #expect(sources(replay, 14...15) == [.fused], "back to corrected tracking")
        #expect(resets(replay).isEmpty)
    }

    /// Holding the phone still adds no depth evidence, so calibration must not
    /// be approved however many views arrive.
    @Test func holdingStillNeverCalibrates() throws {
        var recording = SyntheticRecording()
        try recording.seen(20, moving: .zero)

        let replay = try TraceReplay(recording.trace())

        #expect(replay.steps.map(\.calibrationReady) == Array(repeating: false, count: 20))
        #expect(sources(replay, 0...19) == [.visual])
    }

    @Test func newWorldSessionResetsCalibration() throws {
        var recording = SyntheticRecording()
        try recording.seen(10)
        recording.session = UUID(uuidString: "C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B")!
        try recording.seen()          // frame 10

        let replay = try TraceReplay(recording.trace())

        let reset = resets(replay)
        #expect(reset.map(\.index) == [10])
        #expect(reset.first?.change == .reset(reason: "World session replaced"))
        #expect(replay.steps.last?.calibrationReady == false)
    }

    @Test func newReferenceResetsCalibration() throws {
        var recording = SyntheticRecording()
        try recording.seen(10)
        recording.reference = UUID(uuidString: "9E8D7C6B-5A49-4382-9170-6F5E4D3C2B1A")!
        try recording.seen()          // frame 10

        let replay = try TraceReplay(recording.trace())

        #expect(resets(replay).map(\.change) == [.reset(reason: "Reference replaced")])
        #expect(replay.steps.last?.calibrationReady == false)
    }

    /// Serialization fidelity, not policy behaviour: a trace read back from
    /// disk must drive the policy exactly as the in-memory one does.
    @Test func replayAfterDecodingMatchesReplayInMemory() throws {
        var recording = SyntheticRecording()
        try recording.seen(10)
        recording.lost(4)
        try recording.seen(2)
        let trace = recording.trace()

        let fromDisk = try TraceReplay(CalibrationTrace.decode(trace.encoded()))
        let inMemory = try TraceReplay(trace)

        #expect(fromDisk.steps == inMemory.steps)
    }

    @Test func malformedTraceRefusesToReplay() throws {
        var recording = SyntheticRecording()
        try recording.seen(3)
        var trace = recording.trace()
        trace.frames[1].index = 0

        #expect(throws: TraceDecodingError.self) { try TraceReplay(trace) }
    }
}
