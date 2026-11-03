//
//  CalibrationTrace.swift
//  Tracking
//
//  Created by Miguel Tjia on 11/2/26.
//

import Foundation
import simd

struct TracePlane: Codable {
    var transform: [Float]
    var extent: [Float]

    init(_ plane: WorldPlane) {
        let m = plane.transform
        transform = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                     m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                     m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                     m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        extent = [plane.extent.x, plane.extent.y]
    }

    func plane() throws -> WorldPlane {
        guard transform.count == 16 else {
            throw TraceDecodingError.wrongCount(field: "transform", expected: 16, actual: transform.count)
        }
        guard extent.count == 2 else {
            throw TraceDecodingError.wrongCount(field: "extent", expected: 2, actual: extent.count)
        }
        let c0 = SIMD4<Float>(transform[0], transform[1], transform[2], transform[3])
        let c1 = SIMD4<Float>(transform[4], transform[5], transform[6], transform[7])
        let c2 = SIMD4<Float>(transform[8], transform[9], transform[10], transform[11])
        let c3 = SIMD4<Float>(transform[12], transform[13], transform[14], transform[15])
        let matrix = simd_float4x4(c0, c1, c2, c3)
        return WorldPlane(transform: matrix, extent: SIMD2(extent[0], extent[1]))
    }
}

enum TraceDecodingError: Error {
    case wrongCount(field: String, expected: Int, actual: Int)
}

