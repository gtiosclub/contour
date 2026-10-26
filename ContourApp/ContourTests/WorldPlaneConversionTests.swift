import Testing
import simd
import Tracking
@testable import ContourApp

@Suite("AR plane conversion")
struct WorldPlaneConversionTests {
    @Test("The plane origin is the extent's center, offset in anchor space")
    func originIsExtentCenter() {
        let anchor = translation(1, 2, 3) * rotationY(.pi / 2)
        let plane = WorldPlane(anchorTransform: anchor, center: SIMD3(1, 0, 0),
                               rotationOnYAxis: 0, width: 2, height: 1)
        // Anchor x points along world -z after its quarter turn.
        expectClose(plane.transform.columns.3, SIMD4(1, 2, 2, 1))
        #expect(plane.extent == SIMD2(2, 1))
    }

    @Test("Extent rotation turns local x/z about the unchanged normal")
    func extentRotationKeepsNormal() {
        let plane = WorldPlane(anchorTransform: matrix_identity_float4x4, center: .zero,
                               rotationOnYAxis: .pi / 2, width: 2, height: 1)
        expectClose(plane.transform.columns.0, SIMD4(0, 0, -1, 0))
        expectClose(plane.transform.columns.1, SIMD4(0, 1, 0, 0))
        expectClose(plane.transform.columns.2, SIMD4(1, 0, 0, 0))
    }

    private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(x, y, z, 1)
        return matrix
    }

    private func rotationY(_ angle: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)))
    }

    private func expectClose(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(simd_distance(actual, expected) < 1e-5, "\(actual) ≠ \(expected)",
                sourceLocation: sourceLocation)
    }
}
