import ARKit
import simd
import Tracking

extension WorldPlane {
    /// A plane anchor as this frame saw it. Candidates only: Geometry decides
    /// which plane, if any, holds the panel.
    nonisolated init(_ anchor: ARPlaneAnchor) {
        self.init(anchorTransform: anchor.transform, center: anchor.center,
                  rotationOnYAxis: anchor.planeExtent.rotationOnYAxis,
                  width: anchor.planeExtent.width, height: anchor.planeExtent.height)
    }

    /// The anchor's origin is not the extent's center, and the extent can be
    /// rotated about the anchor's normal. Both are folded into `transform`, so
    /// its origin is the center and local x/z run along width/height.
    nonisolated init(anchorTransform: simd_float4x4, center: SIMD3<Float>,
                     rotationOnYAxis: Float, width: Float, height: Float) {
        var offset = matrix_identity_float4x4
        offset.columns.3 = SIMD4(center, 1)
        let rotation = simd_float4x4(simd_quatf(angle: rotationOnYAxis, axis: SIMD3(0, 1, 0)))
        self.init(transform: anchorTransform * offset * rotation, extent: SIMD2(width, height))
    }
}
