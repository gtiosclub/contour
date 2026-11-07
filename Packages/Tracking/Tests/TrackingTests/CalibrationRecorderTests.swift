//
//  CalibrationRecorderTests.swift
//  Tracking
//
//  The recorder against a scripted camera and tracker, end to end through the
//  file format and replay. Every trace here is synthetic and says so.
//

import ContourCore
import ContourMocks
import CoreVideo
import Foundation
import Testing
import simd
@testable import Tracking

// MARK: - Buffer bookkeeping

private func anyFrame(_ index: Int) -> TraceFrame {
    let time = HybridScene.start.addingTimeInterval(Double(index) / 30)
    return TraceFrame(index: index, timestamp: time, orientation: .right, referenceID: nil,
                      visual: .lost(.notFound, at: time), world: nil)
}

@Suite("Trace buffer")
struct TraceBufferTests {
    @Test func samplingKeepsOneFrameInN() {
        var buffer = TraceBuffer(capacity: 100, everyNthFrame: 3)
        for _ in 0..<7 where buffer.offer() { buffer.append(anyFrame(buffer.lastOffered)) }

        #expect(buffer.frames.map(\.index) == [0, 3, 6])
        #expect(buffer.dropped == 4)
    }

    @Test func fullBufferKeepsTheNewestFrames() {
        var buffer = TraceBuffer(capacity: 3, everyNthFrame: 1)
        for _ in 0..<5 where buffer.offer() { buffer.append(anyFrame(buffer.lastOffered)) }

        #expect(buffer.frames.map(\.index) == [2, 3, 4])
        #expect(buffer.frames.count + buffer.dropped == buffer.offered, "every frame accounted for")
    }
}

// MARK: - Scripted camera and tracker

/// What the scripted visual tracker does with each delivered frame.
private enum Reply: Sendable { case seen, covered, fails }

/// The phone's path: one HybridScene camera per frame, 0.15 s apart.
private func cameraFrames(moves: [SIMD3<Float>]) throws -> [CameraFrame] {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try #require(buffer)
    var position = SIMD3<Float>.zero
    return moves.enumerated().map { index, move in
        position += move
        return CameraFrame(pixelBuffer: pixels,
                           timestamp: HybridScene.start.addingTimeInterval(Double(index + 1) * 0.15),
                           orientation: .right,
                           world: HybridScene.camera(at: position, planes: [HybridScene.surface(at: 0.5)]))
    }
}

private struct ScriptedCamera: CameraFrameSource, @unchecked Sendable {
    let frames: [CameraFrame]
    func cameraFrames() async -> AsyncStream<CameraFrame> {
        AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }
}

private actor ScriptedTracker: PanelTracking {
    let script: [Reply]
    private var calls = 0
    private(set) var stopped = false

    init(_ script: [Reply]) { self.script = script }

    func startTracking(_ reference: PanelReference) async throws {}

    func track(_ frame: CameraFrame) async throws -> PanelObservation {
        defer { calls += 1 }
        switch script[calls] {
        case .seen:
            let world = try #require(frame.world)
            let quad = try #require(try HybridScene.seen(from: world, at: 0).quad)
            return .tracked(quad, confidence: 0.9, at: frame.timestamp)
        case .covered:
            return .lost(.notFound, at: frame.timestamp)
        case .fails:
            throw PanelTrackingError.frameInFlight
        }
    }

    func stopTracking() async { stopped = true }
}

/// Scripted tracking never decodes the photo, so any bytes will do.
private func reference() throws -> PanelReference {
    let photo = PanelPhoto(data: Data([0]), pixelSize: PixelSize(width: 64, height: 48),
                           timestamp: HybridScene.start)
    let quad = PanelQuad(topLeft: ImagePoint(x: 0.25, y: 0.25), topRight: ImagePoint(x: 0.75, y: 0.25),
                         bottomRight: ImagePoint(x: 0.75, y: 0.75), bottomLeft: ImagePoint(x: 0.25, y: 0.75))
    return try PanelReference(photo: photo, detection: PanelDetection(
        referencePhotoID: photo.id, quad: quad, map: MockSurfaceMaps.microwave))
}

private func notes(_ expected: [TraceNotes.ExpectedEvent]) -> TraceNotes {
    TraceNotes(synthetic: true, device: "none (scripted camera)", system: "none",
               conditions: "HybridScene panel at 0.5 m", operatorNotes: "", expectedEvents: expected)
}

// MARK: - Recording

@Suite("Calibration recorder")
struct CalibrationRecorderTests {
    /// The issue's example, recorded rather than built by hand. Ten sideways
    /// views (0.15...1.5 s), one frame the tracker fails on (1.65 s), the panel
    /// covered without moving (1.8...2.25 s), then seen again (2.4, 2.55 s).
    /// The expectations are written from that script, not from a replay.
    @Test func recordedSessionReplaysAsScripted() async throws {
        let replies: [Reply] = Array(repeating: .seen, count: 10) + [.fails]
            + Array(repeating: .covered, count: 4) + [.seen, .seen]
        let moves = Array(repeating: HybridScene.sideways, count: 10) + Array(repeating: .zero, count: 5)
            + [HybridScene.sideways, HybridScene.sideways]
        let tracker = ScriptedTracker(replies)
        let recorder = CalibrationRecorder()

        try await recorder.record(camera: ScriptedCamera(frames: cameraFrames(moves: moves)),
                                  tracker: tracker, reference: reference())

        // Offsets below are from the first recorded frame, at 0.15 s.
        let expected = [
            TraceNotes.ExpectedEvent(change: "ready.true", earliest: 0, latest: 1.35,
                                     description: "calibrated during the sideways sweep"),
            TraceNotes.ExpectedEvent(change: "source.world", earliest: 1.6, latest: 1.7,
                                     description: "AR prediction on the first covered frame"),
            TraceNotes.ExpectedEvent(change: "source.fused", earliest: 2.2, latest: 2.3,
                                     description: "corrected tracking once uncovered"),
            TraceNotes.ExpectedEvent(change: "reset", earliest: 0, latest: 3, occurs: false,
                                     description: "nothing invalidated the model"),
        ]
        let trace = try CalibrationTrace.decode(await recorder.encodedTrace(notes: notes(expected)))

        #expect(trace.sampling.framesOffered == 17)
        #expect(trace.sampling.framesDropped == 1, "the frame the tracker failed on")
        #expect(trace.frames.map(\.index).contains(10) == false)
        #expect(trace.frames.allSatisfy { $0.world != nil }, "each observation kept its world snapshot")
        #expect(await tracker.stopped)
        #expect(try TraceReplay(trace).unmet(trace.notes.expectedEvents).isEmpty)
    }

    /// The check has to be able to fail, or a passing replay proves nothing.
    @Test func unmetReportsWhatDidNotHappen() async throws {
        let recorder = CalibrationRecorder()
        try await recorder.record(
            camera: ScriptedCamera(frames: cameraFrames(moves: Array(repeating: .zero, count: 12))),
            tracker: ScriptedTracker(Array(repeating: .seen, count: 12)), reference: reference())

        let impossible = TraceNotes.ExpectedEvent(change: "ready.true", earliest: 0, latest: 10,
                                                  description: "a phone held still cannot calibrate")
        let trace = try CalibrationTrace.decode(await recorder.encodedTrace(notes: notes([impossible])))

        #expect(try TraceReplay(trace).unmet(trace.notes.expectedEvents) == [impossible])
    }
}

// MARK: - Phone recordings

/// Real traces in Fixtures/Traces, each checked against the expectations its
/// operator wrote down. Empty until traces are recorded on a phone.
private let phoneTraces: [URL] =
    Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures/Traces") ?? []

@Suite("Recorded phone traces")
struct PhoneTraceRegressionTests {
    @Test(arguments: phoneTraces)
    func replaysAsTheOperatorObserved(_ url: URL) throws {
        let trace = try CalibrationTrace.decode(Data(contentsOf: url))

        #expect(!trace.notes.synthetic, "Fixtures/Traces is for phone recordings only")
        #expect(!trace.notes.expectedEvents.isEmpty, "a trace with nothing written down checks nothing")
        let unmet = try TraceReplay(trace).unmet(trace.notes.expectedEvents)
        #expect(unmet.isEmpty, "\(url.lastPathComponent): \(unmet.map(\.description))")
    }
}
