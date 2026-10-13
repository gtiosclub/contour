import Foundation
import simd

/// Immutable, same-frame AR data. Pixels/intrinsics use native landscape sensor
/// coordinates; public ImagePoints use upright portrait coordinates, y down.
public struct WorldCameraSnapshot: Sendable {
    public let sessionID: UUID
    public let cameraToWorld: simd_float4x4
    public let intrinsics: simd_float3x3
    public let imageSize: SIMD2<Float>
    public let normalTracking: Bool
    public let planes: [WorldPlane]

    public init(sessionID: UUID, cameraToWorld: simd_float4x4, intrinsics: simd_float3x3,
                imageSize: SIMD2<Float>, normalTracking: Bool, planes: [WorldPlane]) {
        self.sessionID = sessionID; self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics; self.imageSize = imageSize
        self.normalTracking = normalTracking; self.planes = planes
    }
}

public struct WorldPlane: Sendable {
    /// Local x/z span the plane; local y is its normal. Origin is extent center.
    public let transform: simd_float4x4
    public let extent: SIMD2<Float>
    public init(transform: simd_float4x4, extent: SIMD2<Float>) {
        self.transform = transform; self.extent = extent
    }
}
