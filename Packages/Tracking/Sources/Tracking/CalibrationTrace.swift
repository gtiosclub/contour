//
//  CalibrationTrace.swift
//  Tracking
//
//  Created by Miguel Tjia on 11/2/26.
//

import ContourCore
import Foundation
import ImageIO
import simd

/// A recorded session: every frame the recorder kept, plus what the operator
/// knew about it. The file a teammate replays without a phone.
struct CalibrationTrace: Codable {
    static let currentFormatVersion = 1

    typealias Notes = TraceNotes

    struct Sampling: Codable {
        /// Frames the camera delivered to the recorder.
        var framesOffered: Int
        /// Frames delivered but not in the trace: skipped by sampling, failed
        /// by the tracker, or evicted from the bounded buffer.
        var framesDropped: Int
        /// The recorder kept at most one frame in this many.
        var everyNthFrame: Int = 1
    }

    var formatVersion: Int
    var notes: Notes
    var sampling: Sampling
    var frames: [TraceFrame]

    init(notes: Notes, sampling: Sampling, frames: [TraceFrame]) {
        formatVersion = Self.currentFormatVersion
        self.notes = notes
        self.sampling = sampling
        self.frames = frames
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes and validates. A trace that decodes but breaks an invariant throws.
    static func decode(_ data: Data) throws -> CalibrationTrace {
        let trace = try JSONDecoder().decode(CalibrationTrace.self, from: data)
        try trace.validate()
        return trace
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw TraceDecodingError.unsupportedVersion(formatVersion)
        }
        // Every delivered frame is either in the trace or counted as dropped.
        guard sampling.framesOffered == frames.count + sampling.framesDropped else {
            throw TraceDecodingError.inconsistentSampling
        }
        for (previous, next) in zip(frames, frames.dropFirst()) {
            guard next.index > previous.index else {
                throw TraceDecodingError.outOfOrder(index: next.index)
            }
            guard next.timestamp >= previous.timestamp else {
                throw TraceDecodingError.outOfOrder(index: next.index)
            }
        }
    }
}

/// What the operator knew about a recording, written down when it was made.
public struct TraceNotes: Codable, Sendable {
    /// Something the operator saw happen, as a window of seconds since the
    /// trace's first frame. Replay checks these; they are never derived from a
    /// replay of the same trace.
    public struct ExpectedEvent: Codable, Hashable, Sendable {
        /// A `TraceReplay.Change.label`, e.g. "ready.true", "source.world", "reset".
        public var change: String
        public var earliest: TimeInterval
        public var latest: TimeInterval
        /// False for "this must not happen inside the window".
        public var occurs: Bool
        public var description: String

        public init(change: String, earliest: TimeInterval, latest: TimeInterval,
                    occurs: Bool = true, description: String) {
            self.change = change
            self.earliest = earliest
            self.latest = latest
            self.occurs = occurs
            self.description = description
        }
    }

    /// True for traces generated in code. Never label these phone recordings.
    public var synthetic: Bool
    public var device: String
    public var system: String
    public var conditions: String
    public var operatorNotes: String
    public var expectedEvents: [ExpectedEvent]

    public init(synthetic: Bool, device: String, system: String, conditions: String,
                operatorNotes: String, expectedEvents: [ExpectedEvent]) {
        self.synthetic = synthetic
        self.device = device
        self.system = system
        self.conditions = conditions
        self.operatorNotes = operatorNotes
        self.expectedEvents = expectedEvents
    }
}

/// One camera frame. The visual observation and world snapshot came from the
/// same pixels; keeping them in one record is what preserves that pairing.
struct TraceFrame: Codable {
    /// Capture sequence number. A gap is a frame the recorder dropped.
    var index: Int
    var timestamp: Date
    /// A CGImagePropertyOrientation raw value.
    var orientation: UInt32
    /// The reference photo the visual tracker was matching against.
    var referenceID: UUID?
    var visual: TraceObservation
    var world: TraceWorldSnapshot?

    init(index: Int, timestamp: Date, orientation: CGImagePropertyOrientation, referenceID: UUID?,
         visual: PanelObservation, world: WorldCameraSnapshot?) {
        self.index = index
        self.timestamp = timestamp
        self.orientation = orientation.rawValue
        self.referenceID = referenceID
        self.visual = TraceObservation(visual)
        self.world = world.map(TraceWorldSnapshot.init)
    }

    func imageOrientation() throws -> CGImagePropertyOrientation {
        guard let orientation = CGImagePropertyOrientation(rawValue: orientation) else {
            throw TraceDecodingError.unknownValue(field: "orientation", value: String(orientation))
        }
        return orientation
    }

    /// The alignment policy's inputs for this frame.
    func inputs() throws -> (visual: PanelObservation, world: WorldCameraSnapshot?) {
        let visual = try visual.observation()
        // An observation stamped with another frame's time is not this frame's.
        guard visual.timestamp == timestamp else {
            throw TraceDecodingError.mismatchedFrame(index: index)
        }
        return (visual, try world?.snapshot())
    }
}

/// Recording form of a PanelObservation. Of the feature diagnostics only the
/// saturated fraction is kept: the alignment policy reads it for glare, and
/// the rest is tracker output it never looks at.
struct TraceObservation: Codable {
    var timestamp: Date
    var quad: PanelQuad?
    var confidence: Double
    /// "tracked" or "lost".
    var status: String
    /// A PanelObservation.LossReason raw value; present exactly when lost.
    var lossReason: String?
    /// FeatureTrackingDiagnostics.saturatedFraction, when the tracker reported one.
    var saturatedFraction: Double?

    init(_ observation: PanelObservation) {
        timestamp = observation.timestamp
        quad = observation.quad
        confidence = observation.confidence
        saturatedFraction = observation.featureDiagnostics?.saturatedFraction
        switch observation.status {
        case .tracked:
            status = "tracked"
            lossReason = nil
        case .lost(let reason):
            status = "lost"
            lossReason = reason.rawValue
        }
    }

    func observation() throws -> PanelObservation {
        var observation: PanelObservation
        switch (status, quad, lossReason) {
        case ("tracked", let quad?, nil):
            observation = .tracked(quad, confidence: confidence, at: timestamp)
        case ("lost", nil, let raw?):
            guard let reason = PanelObservation.LossReason(rawValue: raw) else {
                throw TraceDecodingError.unknownValue(field: "lossReason", value: raw)
            }
            observation = .lost(reason, at: timestamp)
        case ("tracked", _, _), ("lost", _, _):
            // A quad must be present exactly when tracked.
            throw TraceDecodingError.inconsistentObservation(status: status)
        default:
            throw TraceDecodingError.unknownValue(field: "status", value: status)
        }
        if let saturatedFraction {
            observation.featureDiagnostics = Self.replayedEvidence(saturatedFraction: saturatedFraction)
        }
        return observation
    }

    /// Diagnostics carrying only what was recorded. The other counts are zero,
    /// not reconstructed; the message says so.
    private static func replayedEvidence(saturatedFraction: Double) -> FeatureTrackingDiagnostics {
        FeatureTrackingDiagnostics(
            referenceFeatures: 0, frameFeatures: 0, matchCount: 0, inlierCount: 0,
            coverage: 0, reprojectionError: 0, processingMilliseconds: 0,
            message: "Replayed: only the saturated fraction was recorded", inlierPoints: [],
            saturatedFraction: saturatedFraction, excludedHighlightFraction: 0)
    }
}

struct TracePlane: Codable {
    var transform: [Float]
    var extent: [Float]

    init(_ plane: WorldPlane) {
        transform = flatten(plane.transform)
        extent = [plane.extent.x, plane.extent.y]
    }

    func plane() throws -> WorldPlane {
        WorldPlane(transform: try matrix4(transform, field: "transform"),
                   extent: try vector2(extent, field: "extent"))
    }
}

struct TraceWorldSnapshot: Codable {
    var sessionID: UUID
    var cameraToWorld: [Float]
    var intrinsics: [Float]
    var imageSize: [Float]
    var normalTracking: Bool
    var planes: [TracePlane]

    init(_ snapshot: WorldCameraSnapshot) {
        sessionID = snapshot.sessionID
        cameraToWorld = flatten(snapshot.cameraToWorld)
        intrinsics = flatten(snapshot.intrinsics)
        imageSize = [snapshot.imageSize.x, snapshot.imageSize.y]
        normalTracking = snapshot.normalTracking
        planes = snapshot.planes.map(TracePlane.init)
    }

    func snapshot() throws -> WorldCameraSnapshot {
        WorldCameraSnapshot(sessionID: sessionID,
                            cameraToWorld: try matrix4(cameraToWorld, field: "cameraToWorld"),
                            intrinsics: try matrix3(intrinsics, field: "intrinsics"),
                            imageSize: try vector2(imageSize, field: "imageSize"),
                            normalTracking: normalTracking,
                            planes: try planes.map { try $0.plane() })
    }
}

enum TraceDecodingError: Error {
    case wrongCount(field: String, expected: Int, actual: Int)
    case unknownValue(field: String, value: String)
    case inconsistentObservation(status: String)
    case unsupportedVersion(Int)
    case inconsistentSampling
    case outOfOrder(index: Int)
    case mismatchedFrame(index: Int)
}

// Matrices are stored column-major: column 0 first, then column 1, ...

private func flatten(_ m: simd_float4x4) -> [Float] {
    [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
}

private func flatten(_ m: simd_float3x3) -> [Float] {
    [m.columns.0, m.columns.1, m.columns.2].flatMap { [$0.x, $0.y, $0.z] }
}

private func checkCount(_ values: [Float], _ expected: Int, field: String) throws {
    guard values.count == expected else {
        throw TraceDecodingError.wrongCount(field: field, expected: expected, actual: values.count)
    }
}

private func matrix4(_ v: [Float], field: String) throws -> simd_float4x4 {
    try checkCount(v, 16, field: field)
    return simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                         SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
}

private func matrix3(_ v: [Float], field: String) throws -> simd_float3x3 {
    try checkCount(v, 9, field: field)
    return simd_float3x3(SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]))
}

private func vector2(_ v: [Float], field: String) throws -> SIMD2<Float> {
    try checkCount(v, 2, field: field)
    return SIMD2(v[0], v[1])
}

