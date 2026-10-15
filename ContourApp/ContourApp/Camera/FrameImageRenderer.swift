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
