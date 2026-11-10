//
//  PanelWorldGeometryTests.swift
//  Tracking — Tracking / Geometry and fusion
//
//  Synthetic cameras and planes only: no ARSession, no device, no fixtures.
//  Every expected pixel below is worked out by hand from the stated convention,
//  so a sign flip fails a test instead of quietly moving a blind user's finger.
//

import ContourCore
import Foundation
import Testing
import simd
@testable import Tracking

// MARK: - Fixtures

/// Native landscape sensor, as ARKit reports it.
private let sensor = SIMD2<Float>(1920, 1440)
private let focal: Float = 1500

/// A camera looking down world -z, optionally moved and turned.
///
/// Remember the basis: camera +x runs along the sensor's long axis, which is
/// *down* the portrait screen, and camera +y is portrait-right.
private func camera(
    at translation: SIMD3<Float> = .zero,
    turnedBy radians: Float = 0,
    about axis: SIMD3<Float> = SIMD3(0, 1, 0)
) -> WorldCameraSnapshot {
    var transform = radians == 0
        ? matrix_identity_float4x4
        : simd_float4x4(simd_quatf(angle: radians, axis: simd_normalize(axis)))
    transform.columns.3 = SIMD4(translation, 1)
    return WorldCameraSnapshot(
        sessionID: UUID(),
        cameraToWorld: transform,
        intrinsics: simd_float3x3(SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(960, 720, 1)),
        imageSize: sensor,
        normalTracking: true,
        planes: []
    )
}

/// A plane `distance` metres in front of the origin, facing the camera.
/// Local y is its normal (+z here); local x/z span the extent.
private func wall(at distance: Float, extent: SIMD2<Float> = SIMD2(0.4, 0.3)) -> WorldPlane {
    WorldPlane(
        transform: simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, -1, 0, 0),
            SIMD4(0, 0, -distance, 1)
        ),
        extent: extent
    )
}

/// Round trips are exact arithmetic, so the tolerance only absorbs the float →
/// double widening of the inputs.
private let tolerance = 1e-6

private func expectClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ note: Comment? = nil) {
    #expect(abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.z - b.z) < tolerance, note)
}

private func expectClose(_ a: ImagePoint, _ b: ImagePoint, _ note: Comment? = nil) {
    #expect(abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance, note)
}

// MARK: - Ray

@Test("the centre pixel looks straight down the camera's forward axis")
func centreRayIsForward() throws {
    let ray = try PanelWorldGeometry(snapshot: camera()).ray(through: ImagePoint(x: 0.5, y: 0.5))

    expectClose(ray.origin, SIMD3(0, 0, 0))
    expectClose(ray.direction, SIMD3(0, 0, -1), "the camera looks along -z")
}

@Test("the ray starts at the camera, wherever the camera is")
func rayOriginFollowsTheCamera() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera(at: SIMD3(0.2, -0.1, 0.4)))

    let ray = try geometry.ray(through: ImagePoint(x: 0.3, y: 0.8))

    expectClose(ray.origin, SIMD3(0.2, -0.1, 0.4))
    #expect(abs(simd_length(ray.direction) - 1) < tolerance, "direction is unit length")
}

@Test("a nonfinite image point is rejected rather than propagated")
func nonfiniteImagePointIsRejected() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())

    #expect(throws: WorldGeometryError.nonfiniteResult) {
        try geometry.ray(through: ImagePoint(x: .nan, y: 0.5))
    }
}

// MARK: - Round trips

@Test("the panel centre survives image → world → image")
func centreRoundTrip() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    let centre = ImagePoint(x: 0.5, y: 0.5)

    let world = try geometry.position(of: centre, on: wall(at: 0.5))
    expectClose(world, SIMD3(0, 0, -0.5), "straight ahead at the plane's distance")
    expectClose(try geometry.imagePoint(for: world), centre)
}

@Test("off-centre points round trip, with the pixel worked out by hand")
func offCentreRoundTrip() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    let point = ImagePoint(x: 0.7, y: 0.3)

    // Portrait (0.7, 0.3) is sensor (u, v) = (0.3·1920, 0.3·1440) = (576, 432),
    // so the ray leaves the camera along ((576-960)/1500, -(432-720)/1500, -1)
    // = (-0.256, 0.192, -1), which meets the plane 0.5 m ahead at:
    let world = try geometry.position(of: point, on: wall(at: 0.5))
    expectClose(world, SIMD3(-0.128, 0.096, -0.5))
    expectClose(try geometry.imagePoint(for: world), point)
}

@Test("every corner of an off-centre quad round trips, keeping its identity",
      arguments: [
        ImagePoint(x: 0.42, y: 0.31),
        ImagePoint(x: 0.58, y: 0.33),
        ImagePoint(x: 0.61, y: 0.52),
        ImagePoint(x: 0.39, y: 0.49),
      ])
func cornerRoundTrip(corner: ImagePoint) throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())

    let world = try geometry.position(of: corner, on: wall(at: 0.5))
    expectClose(try geometry.imagePoint(for: world), corner)
}

@Test("a whole quad round trips without rotating its corners")
func quadRoundTrip() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    // Deliberately lopsided: if TL and TR were ever swapped, a symmetric quad
    // would still pass.
    let quad = PanelQuad(
        topLeft: ImagePoint(x: 0.42, y: 0.31),
        topRight: ImagePoint(x: 0.58, y: 0.33),
        bottomRight: ImagePoint(x: 0.61, y: 0.52),
        bottomLeft: ImagePoint(x: 0.39, y: 0.49)
    )

    let corners = try geometry.corners(of: quad, on: wall(at: 0.5))
    let projected = try geometry.quad(for: corners)

    expectClose(projected.topLeft, quad.topLeft)
    expectClose(projected.topRight, quad.topRight)
    expectClose(projected.bottomRight, quad.bottomRight)
    expectClose(projected.bottomLeft, quad.bottomLeft)
}

@Test("a position found in one view projects correctly from a moved camera")
func translatedCameraSeesTheSamePanel() throws {
    let first = try PanelWorldGeometry(snapshot: camera())
    let world = try first.position(of: ImagePoint(x: 0.5, y: 0.5), on: wall(at: 0.5))

    // 5 cm along camera +x, which is 5 cm down the portrait screen.
    let moved = try PanelWorldGeometry(snapshot: camera(at: SIMD3(0.05, 0, 0)))
    let seen = try moved.imagePoint(for: world)

    // p_cam = (-0.05, 0, -0.5) → u = 1500·(-0.1) + 960 = 810 → y = 810/1920.
    expectClose(seen, ImagePoint(x: 0.5, y: 810.0 / 1920.0))
    #expect(seen.y < 0.5, "moving the phone down moves the panel up the screen")

    // And the moved view can recover the same world position from that pixel.
    expectClose(try moved.position(of: seen, on: wall(at: 0.5)), world)
}

@Test("a turned camera round trips too")
func rotatedCameraRoundTrip() throws {
    let turned = try PanelWorldGeometry(snapshot: camera(turnedBy: 0.1))
    let world = SIMD3<Double>(0, 0, -0.5)

    let seen = try turned.imagePoint(for: world)
    #expect(seen.x > 0 && seen.x < 1 && seen.y > 0 && seen.y < 1, "still in frame at 0.1 rad")
    expectClose(try turned.position(of: seen, on: wall(at: 0.5)), world)
}

@Test("a panel slightly off the edge of the frame still projects")
func slightlyOffscreenIsAllowed() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    // Sensor u = -0.05·1920 = -96 → 96 px past the top of the portrait frame.
    let world = try geometry.ray(through: ImagePoint(x: 0.5, y: -0.05)).point(at: 0.5)

    let seen = try geometry.imagePoint(for: world)

    #expect(seen.y < 0, "outside the frame")
    #expect(seen.y > -0.1, "but inside the tolerated margin")
}

// MARK: - Rejections

@Test("a ray along the plane has no single intersection")
func parallelRayIsRejected() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    // A plane whose normal is world +x is edge-on to a ray running down -z.
    let edgeOn = WorldPlane(
        transform: simd_float4x4(
            SIMD4(0, 0, -1, 0),
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, -0.5, 1)
        ),
        extent: SIMD2(0.4, 0.3)
    )

    #expect(throws: WorldGeometryError.parallelRay) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.5), on: edgeOn)
    }
}

@Test("a plane too far away is not this panel", arguments: [0.05, 5.0] as [Float])
func implausibleDistanceIsRejected(distance: Float) throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())

    #expect(throws: WorldGeometryError.distanceOutOfRange) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.5), on: wall(at: distance, extent: SIMD2(4, 4)))
    }
}

@Test("an intersection past the plane's edge is rejected")
func outsideExtentIsRejected() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    // 2 cm square at 0.5 m: the centre ray hits it, a corner ray misses.
    let small = wall(at: 0.5, extent: SIMD2(0.02, 0.02))

    #expect(throws: Never.self) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.5), on: small)
    }
    #expect(throws: WorldGeometryError.outsidePlaneExtent) {
        try geometry.position(of: ImagePoint(x: 0.2, y: 0.2), on: small)
    }
}

@Test("the extent margin tolerates a panel at the very edge of a plane")
func extentMarginIsHonoured() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())
    // Hits 12.8 cm off centre; a 0.2 m-wide plane reaches 10 cm, plus 3 cm margin.
    let narrow = wall(at: 0.5, extent: SIMD2(0.2, 0.4))

    #expect(throws: Never.self) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.3), on: narrow)
    }
}

@Test("a point behind the camera cannot be photographed")
func behindCameraIsRejected() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())

    #expect(throws: WorldGeometryError.behindCamera) {
        try geometry.imagePoint(for: SIMD3(0, 0, 0.5))
    }
}

@Test("a projection far outside the frame is rejected")
func outsideImageBoundsIsRejected() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())

    #expect(throws: WorldGeometryError.outsideImageBounds) {
        try geometry.imagePoint(for: SIMD3(0, 2, -0.5))
    }
}

@Test("a zero-extent plane is not a surface")
func invalidPlaneIsRejected() throws {
    let geometry = try PanelWorldGeometry(snapshot: camera())

    #expect(throws: WorldGeometryError.invalidPlane) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.5), on: wall(at: 0.5, extent: .zero))
    }
}

// MARK: - Snapshot validation

@Test("a camera with no focal length is rejected at construction")
func invalidIntrinsicsAreRejected() {
    var snapshot = camera()
    snapshot = WorldCameraSnapshot(
        sessionID: snapshot.sessionID,
        cameraToWorld: snapshot.cameraToWorld,
        intrinsics: simd_float3x3(SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(960, 720, 1)),
        imageSize: sensor,
        normalTracking: true,
        planes: []
    )

    #expect(throws: WorldGeometryError.invalidSnapshot) { try PanelWorldGeometry(snapshot: snapshot) }
}

@Test("a nonfinite or collapsed camera transform is rejected at construction",
      arguments: [Float.nan, 0])
func invalidTransformIsRejected(scale: Float) {
    let broken = WorldCameraSnapshot(
        sessionID: UUID(),
        cameraToWorld: simd_float4x4(diagonal: SIMD4(scale, scale, scale, scale)),
        intrinsics: simd_float3x3(SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(960, 720, 1)),
        imageSize: sensor,
        normalTracking: true,
        planes: []
    )

    #expect(throws: WorldGeometryError.invalidSnapshot) { try PanelWorldGeometry(snapshot: broken) }
}

@Test("a camera with no sensor dimensions is rejected at construction")
func invalidImageSizeIsRejected() {
    let broken = WorldCameraSnapshot(
        sessionID: UUID(),
        cameraToWorld: matrix_identity_float4x4,
        intrinsics: simd_float3x3(SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(960, 720, 1)),
        imageSize: .zero,
        normalTracking: true,
        planes: []
    )

    #expect(throws: WorldGeometryError.invalidSnapshot) { try PanelWorldGeometry(snapshot: broken) }
}

@Test("unreliable world tracking is the policy's call, not this math's")
func normalTrackingIsNotGatedHere() throws {
    let unreliable = WorldCameraSnapshot(
        sessionID: UUID(),
        cameraToWorld: matrix_identity_float4x4,
        intrinsics: simd_float3x3(SIMD3(focal, 0, 0), SIMD3(0, focal, 0), SIMD3(960, 720, 1)),
        imageSize: sensor,
        normalTracking: false,
        planes: []
    )

    let geometry = try PanelWorldGeometry(snapshot: unreliable)
    #expect(throws: Never.self) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.5), on: wall(at: 0.5))
    }
}

// MARK: - Limits

@Test("the distance range is configurable")
func limitsAreConfigurable() throws {
    var limits = WorldGeometryLimits()
    limits.maximumDistance = 6

    let geometry = try PanelWorldGeometry(snapshot: camera(), limits: limits)

    #expect(throws: Never.self) {
        try geometry.position(of: ImagePoint(x: 0.5, y: 0.5), on: wall(at: 5, extent: SIMD2(4, 4)))
    }
}
