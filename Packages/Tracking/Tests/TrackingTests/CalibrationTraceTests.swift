//
//  CalibrationTraceTests.swift
//  Tracking
//
//  Created by Miguel Tjia on 11/2/26.
//

import ContourCore
import Foundation
import Testing
import simd
@testable import Tracking

// MARK: - Fixtures

// Every entry distinct, so a row/column swap or an off-by-one changes the result.
private let cameraToWorld = simd_float4x4(SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8),
                                          SIMD4(9, 10, 11, 12), SIMD4(13, 14, 15, 16))
private let intrinsics = simd_float3x3(SIMD3(1500, 0.5, 0.25), SIMD3(0.75, 1510, 0.125),
                                       SIMD3(960, 720, 1))
private let wall = WorldPlane(
    transform: simd_float4x4(SIMD4(0.1, 0.2, 0.3, 0), SIMD4(0.4, 0.5, 0.6, 0),
                             SIMD4(0.7, 0.8, 0.9, 0), SIMD4(-0.2, 0.1, -0.5, 1)),
    extent: SIMD2(2, 1.5))
private let counter = WorldPlane(
    transform: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0),
                             SIMD4(0, 1, 0, 0), SIMD4(0.3, -0.9, -0.4, 1)),
    extent: SIMD2(0.6, 1.2))

private let snapshot = WorldCameraSnapshot(
    sessionID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
    cameraToWorld: cameraToWorld, intrinsics: intrinsics,
    imageSize: SIMD2(1920, 1440), normalTracking: true, planes: [wall, counter])

private func throughJSON(_ trace: TraceWorldSnapshot) throws -> TraceWorldSnapshot {
    try JSONDecoder().decode(TraceWorldSnapshot.self, from: JSONEncoder().encode(trace))
}

// MARK: - Tests

@Suite("Calibration trace world snapshots")
struct CalibrationTraceTests {
    @Test func worldSnapshotSurvivesJSONRoundTrip() throws {
        let restored = try throughJSON(TraceWorldSnapshot(snapshot)).snapshot()

        #expect(restored.sessionID == snapshot.sessionID)
        #expect(restored.cameraToWorld == snapshot.cameraToWorld)
        #expect(restored.intrinsics == snapshot.intrinsics)
        #expect(restored.imageSize == snapshot.imageSize)
        #expect(restored.normalTracking == snapshot.normalTracking)
    }

    @Test func matricesAreStoredColumnMajor() {
        let trace = TraceWorldSnapshot(snapshot)

        #expect(trace.cameraToWorld == (1...16).map(Float.init))
        #expect(Array(trace.intrinsics[6...8]) == [960, 720, 1])
    }

    @Test func planesSurviveInOrder() throws {
        let restored = try throughJSON(TraceWorldSnapshot(snapshot)).snapshot()

        #expect(restored.planes.count == 2)
        #expect(restored.planes.map(\.transform) == [wall.transform, counter.transform])
        #expect(restored.planes.map(\.extent) == [wall.extent, counter.extent])
    }

    @Test func shortMatrixThrows() throws {
        var trace = TraceWorldSnapshot(snapshot)
        trace.cameraToWorld.removeLast()

        #expect(throws: TraceDecodingError.self) { try throughJSON(trace).snapshot() }
    }

    @Test func malformedPlaneThrows() throws {
        var trace = TraceWorldSnapshot(snapshot)
        trace.planes[1].extent = [0.6]

        #expect(throws: TraceDecodingError.self) { try throughJSON(trace).snapshot() }
    }

    @Test func missingFieldFailsToDecode() {
        let json = Data(#"{"sessionID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","normalTracking":true}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TraceWorldSnapshot.self, from: json)
        }
    }
}

// MARK: - Observations

private let seen = Date(timeIntervalSince1970: 1_767_225_600.125)
private let quad = PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.2), topRight: ImagePoint(x: 0.8, y: 0.15),
                             bottomRight: ImagePoint(x: 0.85, y: 0.7), bottomLeft: ImagePoint(x: 0.12, y: 0.75))

private func throughJSON(_ trace: TraceObservation) throws -> TraceObservation {
    try JSONDecoder().decode(TraceObservation.self, from: JSONEncoder().encode(trace))
}

@Suite("Calibration trace observations")
struct CalibrationTraceObservationTests {
    @Test func trackedObservationSurvivesJSONRoundTrip() throws {
        let observation = PanelObservation.tracked(quad, confidence: 0.83, at: seen)

        #expect(try throughJSON(TraceObservation(observation)).observation() == observation)
    }

    @Test(arguments: [PanelObservation.LossReason.notFound, .trackerFailed, .unrecognized])
    func lostObservationKeepsItsReason(_ reason: PanelObservation.LossReason) throws {
        let observation = PanelObservation.lost(reason, at: seen)

        #expect(try throughJSON(TraceObservation(observation)).observation() == observation)
    }

    @Test func trackedWithoutQuadThrows() {
        var trace = TraceObservation(.tracked(quad, confidence: 0.83, at: seen))
        trace.quad = nil

        #expect(throws: TraceDecodingError.self) { try trace.observation() }
    }

    @Test func lostWithQuadThrows() {
        var trace = TraceObservation(.lost(.notFound, at: seen))
        trace.quad = quad

        #expect(throws: TraceDecodingError.self) { try trace.observation() }
    }

    @Test func unknownLossReasonThrows() {
        var trace = TraceObservation(.lost(.notFound, at: seen))
        trace.lossReason = "cosmicRay"

        #expect(throws: TraceDecodingError.self) { try trace.observation() }
    }

    @Test func unknownStatusThrows() {
        var trace = TraceObservation(.tracked(quad, confidence: 0.83, at: seen))
        trace.status = "maybe"

        #expect(throws: TraceDecodingError.self) { try trace.observation() }
    }

    @Test func saturatedFractionSurvivesForTheGlareCheck() throws {
        var observation = PanelObservation.tracked(quad, confidence: 0.83, at: seen)
        observation.featureDiagnostics = HybridScene.glareEvidence(saturated: 0.4)

        let restored = try throughJSON(TraceObservation(observation)).observation()

        #expect(restored.featureDiagnostics?.saturatedFraction == 0.4)
    }
}

// MARK: - Frames and the file

private let referenceID = UUID(uuidString: "0B7E1A52-3C1D-4F7E-9A55-2D6C8E0F1A23")!

private func frame(_ index: Int, at offset: TimeInterval, world: WorldCameraSnapshot? = snapshot) -> TraceFrame {
    let time = seen.addingTimeInterval(offset)
    return TraceFrame(index: index, timestamp: time, orientation: .right, referenceID: referenceID,
                      visual: .tracked(quad, confidence: 0.83, at: time), world: world)
}

private func file(_ frames: [TraceFrame], offered: Int? = nil, dropped: Int = 0) -> CalibrationTrace {
    CalibrationTrace(
        notes: .init(synthetic: true, device: "none", system: "none", conditions: "unit test",
                     operatorNotes: "", expectedEvents: []),
        sampling: .init(framesOffered: offered ?? frames.count + dropped, framesDropped: dropped),
        frames: frames)
}

@Suite("Calibration trace files")
struct CalibrationTraceFileTests {
    @Test func traceSurvivesEncodeAndDecode() throws {
        let original = file([frame(0, at: 0), frame(2, at: 0.066, world: nil)], offered: 3, dropped: 1)

        let restored = try CalibrationTrace.decode(original.encoded())

        #expect(restored.notes.synthetic)
        #expect(restored.sampling.framesDropped == 1)
        #expect(restored.frames.map(\.index) == [0, 2], "the gap is the dropped frame")
        let first = try restored.frames[0].inputs()
        #expect(first.visual == .tracked(quad, confidence: 0.83, at: seen))
        #expect(first.world?.cameraToWorld == cameraToWorld)
        #expect(try restored.frames[1].inputs().world == nil, "a frame without world data stays without it")
        #expect(try restored.frames[0].imageOrientation() == .right)
        #expect(restored.frames[0].referenceID == referenceID)
    }

    @Test func unsupportedVersionThrows() throws {
        var trace = file([frame(0, at: 0)])
        trace.formatVersion = 99

        #expect(throws: TraceDecodingError.self) { try CalibrationTrace.decode(trace.encoded()) }
    }

    @Test func repeatedIndexThrows() throws {
        let trace = file([frame(3, at: 0), frame(3, at: 0.033)])

        #expect(throws: TraceDecodingError.self) { try CalibrationTrace.decode(trace.encoded()) }
    }

    @Test func timeRunningBackwardsThrows() throws {
        let trace = file([frame(0, at: 0.033), frame(1, at: 0)])

        #expect(throws: TraceDecodingError.self) { try CalibrationTrace.decode(trace.encoded()) }
    }

    @Test func moreFramesThanOfferedThrows() throws {
        let trace = file([frame(0, at: 0), frame(1, at: 0.033)], offered: 1)

        #expect(throws: TraceDecodingError.self) { try CalibrationTrace.decode(trace.encoded()) }
    }

    @Test func observationFromAnotherFrameThrows() {
        var record = frame(0, at: 0)
        record.timestamp = seen.addingTimeInterval(0.033)

        #expect(throws: TraceDecodingError.self) { try record.inputs() }
    }

    @Test func unknownOrientationThrows() {
        var record = frame(0, at: 0)
        record.orientation = 42

        #expect(throws: TraceDecodingError.self) { try record.imageOrientation() }
    }
}
