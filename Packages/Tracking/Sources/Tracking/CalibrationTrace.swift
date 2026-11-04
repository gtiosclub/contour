//
//  CalibrationTrace.swift
//  Tracking
//
//  Created by Miguel Tjia on 11/2/26.
//

import ContourCore
import Foundation
import simd

/// Recording form of a PanelObservation. Diagnostics are not recorded: they
/// are tracker output, not alignment input.
struct TraceObservation: Codable {
    var timestamp: Date
    var quad: PanelQuad?
    var confidence: Double
    /// "tracked" or "lost".
    var status: String
    /// A PanelObservation.LossReason raw value; present exactly when lost.
    var lossReason: String?

    init(_ observation: PanelObservation) {
        timestamp = observation.timestamp
        quad = observation.quad
        confidence = observation.confidence
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
        switch (status, quad, lossReason) {
        case ("tracked", let quad?, nil):
            return .tracked(quad, confidence: confidence, at: timestamp)
        case ("lost", nil, let raw?):
            guard let reason = PanelObservation.LossReason(rawValue: raw) else {
                throw TraceDecodingError.unknownValue(field: "lossReason", value: raw)
            }
            return .lost(reason, at: timestamp)
        case ("tracked", _, _), ("lost", _, _):
            // A quad must be present exactly when tracked.
            throw TraceDecodingError.inconsistentObservation(status: status)
        default:
            throw TraceDecodingError.unknownValue(field: "status", value: status)
        }
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

