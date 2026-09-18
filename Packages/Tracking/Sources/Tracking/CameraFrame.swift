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

    public init(pixelBuffer: CVPixelBuffer, timestamp: Date,
                orientation: CGImagePropertyOrientation = .up) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.orientation = orientation
    }
}

/// Input is injected by the app. Replay adapters can implement this too.
public protocol CameraFrameSource: Sendable {
    func cameraFrames() async -> AsyncStream<CameraFrame>
}
