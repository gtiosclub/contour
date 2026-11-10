import CoreVideo
import Foundation
import ImageIO

/// Apple-platform input adapter, deliberately outside framework-free ContourCore.
/// Buffers are retained for processing and MUST be treated as read-only by every
/// producer and consumer. Make a copy before modifying a buffer's contents.
public struct CameraFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: Date
    public let orientation: CGImagePropertyOrientation
    /// Pose/intrinsics belong to these exact pixels, before upright rotation.
    public let world: WorldCameraSnapshot?

    public init(pixelBuffer: CVPixelBuffer, timestamp: Date,
                orientation: CGImagePropertyOrientation = .up, world: WorldCameraSnapshot? = nil) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.orientation = orientation
        self.world = world
    }
}

/// Input is injected by the app. Replay adapters can implement this too.
public protocol CameraFrameSource: Sendable {
    func cameraFrames() async -> AsyncStream<CameraFrame>
}
