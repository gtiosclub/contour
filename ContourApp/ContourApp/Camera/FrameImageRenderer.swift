import ContourCore
import CoreGraphics
import CoreImage
import ImageIO
import Tracking

/// Pixel rendering is isolated from the UI actor and camera mutation queue.
actor FrameImageRenderer {
    private let context = CIContext()

    func image(for frame: CameraFrame) -> CGImage? {
        render(CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation))
    }

    /// `frame` upright and scaled down so its longer side is at most
    /// `maxLongSide`, for display only. Never enlarges and never crops.
    func previewImage(for frame: CameraFrame, maxLongSide: CGFloat = 960) -> CGImage? {
        let upright = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
        let size = upright.extent.size
        let scale = min(1, maxLongSide / max(size.width, size.height))
        // Whole-pixel output; scaling each axis to its rounded size keeps the
        // full field of view with no fractional edge.
        let width = max(1, (size.width * scale).rounded()), height = max(1, (size.height * scale).rounded())
        let scaled = upright
            .transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: width / size.width, y: height / size.height))
        return context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func image(for photo: PanelPhoto) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let orientation: CGImagePropertyOrientation
        switch photo.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        return render(CIImage(cgImage: pixels).oriented(orientation))
    }

    private func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }
}
