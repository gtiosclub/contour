//
//  FingertipTracker.swift
//  Tracking — Tracking / Fingertip & Frame Math
//
//  Weeks 2–3 deliverable: "Track the index fingertip."
//
//  COORDINATES: you return normalized panel space — (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. Hand tracking gives you camera space;
//  project onto the panel and normalize here, not downstream.
//  See Packages/ContourCore/COORDINATES.md.
//
//  DO NOT CLAMP. A fingertip at y = -0.08 is above the panel, and that is real
//  information guidance depends on. Clamping to 0 lies to the user.
//

import ContourCore
import Foundation

import AVFoundation
@preconcurrency import Vision
import ContourCore
import Foundation

/// Finds the user's index fingertip and places it on the panel.
public struct FingertipTracker: @unchecked Sendable {

    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let sampleBuffer: SampleBufferBox

    public init(sampleBuffer: CMSampleBuffer) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1

        self.handPoseRequest = request
        self.sampleBuffer = SampleBufferBox(sampleBuffer)
    }

    /// Locate the index fingertip for the current camera frame and project
    /// it into normalized panel space.
    ///
    /// Returns nil when:
    /// - no hand is detected;
    /// - the index fingertip is not confidently detected;
    /// - the ray does not intersect the panel;
    /// - the panel pose is invalid.
    ///
    /// The returned point is NOT clamped to 0...1.
    public func fingertip(projectedOnto pose: PanelPose) async -> PanelPoint? {

        guard pose.confidence > 0 else {
            return nil
        }

        let buffer = sampleBuffer.value

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return nil
        }

        let handler = VNImageRequestHandler(
            cmSampleBuffer: buffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([handPoseRequest])

            guard let observation = handPoseRequest.results?.first else {
                return nil
            }

            let points = try observation.recognizedPoints(.indexFinger)

            guard let indexTip = points[.indexTip],
                  indexTip.confidence > 0.3 else {
                return nil
            }

            let width = Double(CVPixelBufferGetWidth(pixelBuffer))
            let height = Double(CVPixelBufferGetHeight(pixelBuffer))

            guard width > 0, height > 0 else {
                return nil
            }

            return project(
                visionPoint: indexTip.location,
                imageWidth: width,
                imageHeight: height,
                pose: pose
            )

        } catch {
            return nil
        }
    }
}

// MARK: - Projection

private extension FingertipTracker {

    /// Converts a Vision fingertip into a camera ray and intersects that ray
    /// with the panel plane.
    ///
    /// MVP assumptions:
    ///
    /// 1. PanelPose maps normalized panel coordinates into camera space.
    /// 2. Therefore the panel occupies:
    ///
    ///        x = 0...1
    ///        y = 0...1
    ///        z = 0
    ///
    ///    in panel-local coordinates.
    ///
    /// 3. Camera space is:
    ///
    ///        +X = right
    ///        +Y = down
    ///        -Z = forward
    ///
    /// 4. Real camera intrinsics are not yet part of the contract.
    ///    The focal length is therefore approximated from the image size.
    func project(
        visionPoint: CGPoint,
        imageWidth: Double,
        imageHeight: Double,
        pose: PanelPose
    ) -> PanelPoint? {

        // -------------------------------------------------------------
        // Vision -> image coordinates
        //
        // Vision:
        //     origin = bottom-left
        //     y increases upward
        //
        // Camera image:
        //     origin = top-left
        //     y increases downward
        // -------------------------------------------------------------

        let imageX = visionPoint.x * imageWidth
        let imageY = (1.0 - visionPoint.y) * imageHeight

        // -------------------------------------------------------------
        // Approximate camera intrinsics.
        //
        // This is intentionally MVP-only. Replace with actual camera
        // intrinsics when Tracking / Spatial exposes them.
        // -------------------------------------------------------------

        let principalX = imageWidth * 0.5
        let principalY = imageHeight * 0.5

        let focalLength = max(imageWidth, imageHeight)

        guard focalLength > 0 else {
            return nil
        }

        // Camera ray.
        //
        // +X = right
        // +Y = down
        // -Z = forward
        let cameraDirection = simd_normalize(
            SIMD3<Double>(
                (imageX - principalX) / focalLength,
                (imageY - principalY) / focalLength,
                -1.0
            )
        )

        let cameraOrigin = SIMD3<Double>(0, 0, 0)

        // -------------------------------------------------------------
        // PanelPose:
        //
        //     panel space -> camera space
        //
        // We need the inverse:
        //
        //     camera space -> panel space
        // -------------------------------------------------------------

        let poseMatrix = simd_double4x4(
            pose.column0,
            pose.column1,
            pose.column2,
            pose.column3
        )

        let inversePose = poseMatrix.inverse

        // Transform camera ray origin.
        let panelOrigin4 = inversePose * SIMD4<Double>(
            cameraOrigin.x,
            cameraOrigin.y,
            cameraOrigin.z,
            1
        )

        // Transform camera ray direction.
        //
        // w = 0 is important: translation must NOT affect a direction.
        let panelDirection4 = inversePose * SIMD4<Double>(
            cameraDirection.x,
            cameraDirection.y,
            cameraDirection.z,
            0
        )

        let panelOrigin = SIMD3<Double>(
            panelOrigin4.x,
            panelOrigin4.y,
            panelOrigin4.z
        )

        let panelDirection = SIMD3<Double>(
            panelDirection4.x,
            panelDirection4.y,
            panelDirection4.z
        )

        // -------------------------------------------------------------
        // Intersect with the panel plane.
        //
        // Panel-local plane:
        //
        //     z = 0
        //
        // Ray:
        //
        //     P = origin + t * direction
        //
        // Therefore:
        //
        //     origin.z + t * direction.z = 0
        //
        //     t = -origin.z / direction.z
        // -------------------------------------------------------------

        guard abs(panelDirection.z) > 1e-9 else {
            return nil
        }

        let t = -panelOrigin.z / panelDirection.z

        // The intersection must be in front of the camera ray.
        guard t >= 0 else {
            return nil
        }

        let intersection =
            panelOrigin + panelDirection * t

        // -------------------------------------------------------------
        // Panel-local XY is already normalized panel space.
        //
        //     x = 0 -> left
        //     x = 1 -> right
        //     y = 0 -> top
        //     y = 1 -> bottom
        //
        // DO NOT CLAMP.
        //
        // A result such as:
        //
        //     (-0.05, 0.42)
        //
        // is valid and means the fingertip is left of the panel.
        // -------------------------------------------------------------

        return PanelPoint(
            x: intersection.x,
            y: intersection.y
        )
    }
}

// MARK: - CMSampleBuffer concurrency boundary

/// Explicitly isolates the non-Sendable AVFoundation frame from the
/// Sendable tracker value.
///
/// This is an MVP boundary. The camera pipeline should eventually own
/// frame isolation/actor confinement more explicitly.
private final class SampleBufferBox: @unchecked Sendable {

    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}
