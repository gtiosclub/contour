//
//  PanelWorldGeometry.swift
//  Tracking — Tracking / Geometry and fusion
//
//  Image points ↔ world positions, through one frame's WorldCameraSnapshot.
//  Pure math: no ARSession, no plane detection, no calibration, no policy.
//
//  A position proposed here is a candidate only. Whether the plane is really at
//  the panel's depth is task 2's question, and whether to trust it during visual
//  loss is task 3's. See docs/TRACKING_FOUNDATION.md.
//
//  COORDINATES — the part to review first:
//  ImagePoint is normalized upright portrait, x right, y down. Intrinsics are in
//  native landscape sensor pixels. Camera space is ARKit's: +x right, +y up,
//  -z forward. World is metres; a plane's local x/z span its centered extent and
//  local y is its normal.
//

import ContourCore
import Foundation
import simd

// MARK: - WorldRay

/// A viewing direction out of the camera, in world space.
public struct WorldRay: Hashable, Sendable {
    /// The camera's world position.
    public var origin: SIMD3<Double>
    /// Unit length, so a distance along it is metres.
    public var direction: SIMD3<Double>

    public init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        self.direction = direction
    }

    /// The point `distance` metres along the ray.
    public func point(at distance: Double) -> SIMD3<Double> {
        origin + direction * distance
    }
}

// MARK: - WorldPanelCorners

/// A panel's four corners in world space, keeping their logical identities.
///
/// Stored as named corners rather than an array because TL/TR/BR/BL identity is
/// the one thing that must survive every conversion — a re-sorted corner is a
/// panel that silently rotates.
public struct WorldPanelCorners: Hashable, Sendable {
    public var topLeft: SIMD3<Double>
    public var topRight: SIMD3<Double>
    public var bottomRight: SIMD3<Double>
    public var bottomLeft: SIMD3<Double>

    public init(topLeft: SIMD3<Double>, topRight: SIMD3<Double>,
                bottomRight: SIMD3<Double>, bottomLeft: SIMD3<Double>) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Perimeter order, matching `PanelQuad`.
    public var all: [SIMD3<Double>] { [topLeft, topRight, bottomRight, bottomLeft] }
}

// MARK: - Errors

/// Every way this math can fail to produce a usable answer. All explicit: a
/// caller never gets a number that quietly means "no".
public enum WorldGeometryError: Error, Equatable {
    /// Nonfinite or non-invertible camera transform, or unusable intrinsics or
    /// sensor dimensions.
    case invalidSnapshot
    /// Nonfinite or non-invertible plane transform, or a non-positive extent.
    case invalidPlane
    /// The ray runs along the plane, so there is no single intersection.
    case parallelRay
    /// The intersection is nearer or further than a panel plausibly is.
    case distanceOutOfRange
    /// The intersection lands off the edge of the plane's extent.
    case outsidePlaneExtent
    /// The world point is behind the camera, which cannot be photographed.
    case behindCamera
    /// The projection lands too far outside the frame to be this panel.
    case outsideImageBounds
    /// The arithmetic produced a NaN or an infinity.
    case nonfiniteResult
}

// MARK: - Limits

/// The guards this math applies, and the starting values for each.
///
/// All are first guesses from issue #85, chosen to reject the implausible while
/// tolerating ordinary boundary slop; they want tuning against recorded
/// sessions, not trust.
public struct WorldGeometryLimits: Hashable, Sendable {
    /// Nearer than this and the "panel" is the user's own hand.
    public var minimumDistance = 0.1
    /// Further than this and it is the far wall, not the appliance in front of you.
    public var maximumDistance = 3.0
    /// How far past a plane's extent an intersection may still count, in metres.
    /// ARKit's extents under-report edges, and a panel often sits at one.
    public var extentMargin = 0.03
    /// A projected corner may leave the frame by this much: a panel partly off
    /// screen is still the panel.
    public var imageBounds = -0.1...1.1
    /// |cos| between ray and plane below this counts as parallel. Small because
    /// a grazing view is geometrically valid, just imprecise.
    public var parallelEpsilon = 1e-6
    /// Determinants below this mean a transform that cannot be inverted.
    public var singularEpsilon = 1e-9

    public init() {}
}

// MARK: - PanelWorldGeometry

/// One frame's camera, ready to convert points.
///
/// Built from a snapshot once and reused: task 2 puts four corners and nine
/// interior samples through the same camera, and validating the matrices per
/// point would be both slower and easier to get inconsistently wrong.
public struct PanelWorldGeometry: Sendable {

    public let limits: WorldGeometryLimits

    private let cameraToWorld: simd_double4x4
    private let worldToCamera: simd_double4x4
    private let focal: SIMD2<Double>
    private let principal: SIMD2<Double>
    /// Native landscape sensor size in pixels, the basis the intrinsics use.
    private let sensor: SIMD2<Double>

    /// - Throws: `invalidSnapshot` if the camera cannot describe a real view.
    public init(snapshot: WorldCameraSnapshot, limits: WorldGeometryLimits = WorldGeometryLimits()) throws {
        self.limits = limits

        let transform = widened(snapshot.cameraToWorld)
        let intrinsics = widened(snapshot.intrinsics)
        let sensor = SIMD2<Double>(snapshot.imageSize)

        guard transform.isFinite, intrinsics.isFinite, sensor.x.isFinite, sensor.y.isFinite else {
            throw WorldGeometryError.invalidSnapshot
        }
        guard abs(transform.determinant) > limits.singularEpsilon else {
            throw WorldGeometryError.invalidSnapshot
        }
        guard sensor.x > 0, sensor.y > 0 else { throw WorldGeometryError.invalidSnapshot }

        // Column-major, as ARKit hands them over: focal lengths on the diagonal,
        // principal point in the last column.
        let focal = SIMD2(intrinsics[0][0], intrinsics[1][1])
        let principal = SIMD2(intrinsics[2][0], intrinsics[2][1])
        guard focal.x > 0, focal.y > 0 else { throw WorldGeometryError.invalidSnapshot }

        self.cameraToWorld = transform
        self.worldToCamera = transform.inverse
        self.focal = focal
        self.principal = principal
        self.sensor = sensor
    }

    // MARK: Image → world

    /// The viewing direction through an image point.
    public func ray(through point: ImagePoint) throws -> WorldRay {
        guard point.x.isFinite, point.y.isFinite else { throw WorldGeometryError.nonfiniteResult }

        let pixel = sensorPixel(point)
        // Camera space is y-up while pixels are y-down, hence the negated y, and
        // the camera looks along -z.
        let cameraDirection = SIMD3(
            (pixel.x - principal.x) / focal.x,
            -(pixel.y - principal.y) / focal.y,
            -1
        )
        let worldDirection = (cameraToWorld * SIMD4(cameraDirection, 0)).xyz
        let length = simd_length(worldDirection)
        guard length.isFinite, length > limits.singularEpsilon else {
            throw WorldGeometryError.nonfiniteResult
        }

        let ray = WorldRay(origin: cameraToWorld.columns.3.xyz, direction: worldDirection / length)
        guard ray.origin.isFinite, ray.direction.isFinite else {
            throw WorldGeometryError.nonfiniteResult
        }
        return ray
    }

    /// Where an image point would sit if the panel lay on `plane`.
    ///
    /// A candidate, not a measurement: a wall behind the panel answers this just
    /// as willingly. Task 2 decides whether the depth is real.
    public func position(of point: ImagePoint, on plane: WorldPlane) throws -> SIMD3<Double> {
        try intersection(of: try ray(through: point), with: plane)
    }

    /// Where `ray` meets `plane`, within the distance and extent guards.
    public func intersection(of ray: WorldRay, with plane: WorldPlane) throws -> SIMD3<Double> {
        let planeToWorld = widened(plane.transform)
        let extent = SIMD2<Double>(plane.extent)
        guard planeToWorld.isFinite, extent.x.isFinite, extent.y.isFinite else {
            throw WorldGeometryError.invalidPlane
        }
        guard abs(planeToWorld.determinant) > limits.singularEpsilon else {
            throw WorldGeometryError.invalidPlane
        }
        guard extent.x > 0, extent.y > 0 else { throw WorldGeometryError.invalidPlane }

        // Local y is the plane's normal; its origin is the centre of the extent.
        let normal = planeToWorld.columns.1.xyz
        let normalLength = simd_length(normal)
        guard normalLength > limits.singularEpsilon else { throw WorldGeometryError.invalidPlane }
        let unitNormal = normal / normalLength

        let denominator = simd_dot(unitNormal, ray.direction)
        guard abs(denominator) > limits.parallelEpsilon else { throw WorldGeometryError.parallelRay }

        let distance = simd_dot(unitNormal, planeToWorld.columns.3.xyz - ray.origin) / denominator
        guard distance.isFinite else { throw WorldGeometryError.nonfiniteResult }
        guard distance >= limits.minimumDistance, distance <= limits.maximumDistance else {
            throw WorldGeometryError.distanceOutOfRange
        }

        let world = ray.point(at: distance)
        guard world.isFinite else { throw WorldGeometryError.nonfiniteResult }

        // Extent is the full width/height about the centre, so compare against
        // half of each, and only on the two axes that span the surface.
        let local = (planeToWorld.inverse * SIMD4(world, 1)).xyz
        guard local.isFinite else { throw WorldGeometryError.nonfiniteResult }
        guard abs(local.x) <= extent.x / 2 + limits.extentMargin,
              abs(local.z) <= extent.y / 2 + limits.extentMargin else {
            throw WorldGeometryError.outsidePlaneExtent
        }
        return world
    }

    /// The panel's four corners on `plane`, identities preserved.
    public func corners(of quad: PanelQuad, on plane: WorldPlane) throws -> WorldPanelCorners {
        WorldPanelCorners(
            topLeft: try position(of: quad.topLeft, on: plane),
            topRight: try position(of: quad.topRight, on: plane),
            bottomRight: try position(of: quad.bottomRight, on: plane),
            bottomLeft: try position(of: quad.bottomLeft, on: plane)
        )
    }

    // MARK: World → image

    /// Where a world position lands in this frame's image.
    ///
    /// This is the one that keeps a stationary panel aligned while the phone
    /// moves: the position is from an earlier view, the camera is from now.
    public func imagePoint(for world: SIMD3<Double>) throws -> ImagePoint {
        guard world.isFinite else { throw WorldGeometryError.nonfiniteResult }

        let camera = (worldToCamera * SIMD4(world, 1)).xyz
        guard camera.isFinite else { throw WorldGeometryError.nonfiniteResult }

        // The camera looks along -z, so anything at or behind z = 0 is not in view.
        let depth = -camera.z
        guard depth > limits.singularEpsilon else { throw WorldGeometryError.behindCamera }

        let pixel = SIMD2(
            focal.x * camera.x / depth + principal.x,
            principal.y - focal.y * camera.y / depth
        )
        guard pixel.x.isFinite, pixel.y.isFinite else { throw WorldGeometryError.nonfiniteResult }

        let point = imagePoint(fromSensor: pixel)
        guard limits.imageBounds.contains(point.x), limits.imageBounds.contains(point.y) else {
            throw WorldGeometryError.outsideImageBounds
        }
        return point
    }

    /// The stored corners projected back into this frame, identities preserved.
    public func quad(for corners: WorldPanelCorners) throws -> PanelQuad {
        PanelQuad(
            topLeft: try imagePoint(for: corners.topLeft),
            topRight: try imagePoint(for: corners.topRight),
            bottomRight: try imagePoint(for: corners.bottomRight),
            bottomLeft: try imagePoint(for: corners.bottomLeft)
        )
    }

    // MARK: Image basis

    // The sensor image is landscape; the upright portrait view is that image
    // rotated 90° clockwise. So portrait x runs back along the sensor's y, and
    // portrait y runs along the sensor's x. These two are inverses of each
    // other, and the round-trip tests are what hold them to it.

    private func sensorPixel(_ point: ImagePoint) -> SIMD2<Double> {
        SIMD2(point.y * sensor.x, (1 - point.x) * sensor.y)
    }

    private func imagePoint(fromSensor pixel: SIMD2<Double>) -> ImagePoint {
        ImagePoint(x: 1 - pixel.y / sensor.y, y: pixel.x / sensor.x)
    }
}

// MARK: - simd helpers

/// simd has no float→double matrix conversion, so widen column by column.
/// Everything here is computed in double: a panel 2 m away is being placed to
/// millimetres, and float's seven digits spend most of that on the metres.
private func widened(_ matrix: simd_float4x4) -> simd_double4x4 {
    simd_double4x4(SIMD4<Double>(matrix.columns.0), SIMD4<Double>(matrix.columns.1),
                   SIMD4<Double>(matrix.columns.2), SIMD4<Double>(matrix.columns.3))
}

private func widened(_ matrix: simd_float3x3) -> simd_double3x3 {
    simd_double3x3(SIMD3<Double>(matrix.columns.0), SIMD3<Double>(matrix.columns.1),
                   SIMD3<Double>(matrix.columns.2))
}

private extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

private extension SIMD3 where Scalar == Double {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension simd_double4x4 {
    var isFinite: Bool { (0..<4).allSatisfy { self[$0].isFinite } }
}

private extension simd_double3x3 {
    var isFinite: Bool { (0..<3).allSatisfy { self[$0].isFinite } }
}
