#if DEBUG
import ContourCore
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Tracking
import UniformTypeIdentifiers

/// Turns saved photos into tracking inputs for the photo replay tool.
///
/// Test photos keep their stored pixels and EXIF orientation, exactly as a
/// camera frame would arrive, so the trackers' own orientation handling is
/// what's exercised. The reference is redrawn upright, because manual corner
/// marking works in the upright image.
nonisolated enum ReplayImageLoader {
    enum LoadError: LocalizedError, Equatable {
        case unreadable(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) isn't an image this tool can read."
            case .tooLarge(let name): "\(name) is larger than \(maximumDimension) pixels on a side."
            }
        }
    }

    /// Larger photos are refused rather than silently resized: the trackers
    /// downsample internally, and replay should feed them what a camera would.
    static let maximumDimension = 8192

    /// One ordered test photo as a camera frame. The timestamp is synthetic
    /// (one per 1/30 s in order); replay doesn't measure real capture time.
    static func frame(from data: Data, name: String, index: Int) throws -> CameraFrame {
        let (image, orientation) = try decode(data, name: name)
        let buffer = try pixelBuffer(for: image, name: name)
        return CameraFrame(pixelBuffer: buffer, timestamp: Date(timeIntervalSinceReferenceDate: Double(index) / 30),
                           orientation: orientation)
    }

    /// The reference photo, drawn upright and re-encoded so its corners can be
    /// marked in the upright image the trackers use.
    static func referencePhoto(from data: Data, name: String) throws -> PanelPhoto {
        let (image, orientation) = try decode(data, name: name)
        let upright = CIImage(cgImage: image).oriented(orientation)
        let origin = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX,
                                                               y: -upright.extent.minY))
        guard let rendered = context.createCGImage(origin, from: origin.extent),
              let encoded = png(rendered) else { throw LoadError.unreadable(name) }
        return PanelPhoto(data: encoded, pixelSize: PixelSize(width: rendered.width, height: rendered.height),
                          orientation: .up, timestamp: Date())
    }

    // MARK: - Decoding

    private static let context = CIContext()

    private static func decode(_ data: Data, name: String) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { throw LoadError.unreadable(name) }
        guard image.width <= maximumDimension, image.height <= maximumDimension else { throw LoadError.tooLarge(name) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// The stored (not rotated) pixels as a BGRA buffer, like a camera's.
    private static func pixelBuffer(for image: CGImage, name: String) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw LoadError.unreadable(name)
        }
        context.render(CIImage(cgImage: image), to: buffer)
        return buffer
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
