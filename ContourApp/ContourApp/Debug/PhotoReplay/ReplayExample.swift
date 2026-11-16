#if DEBUG
import ContourCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A built-in replay example, generated in code so no image files ship:
/// a label-like synthetic panel and three test photos (angled, mostly covered,
/// clear again). The feature tracker should go tracked → lost → recovered.
/// The last photo is stored rotated with an EXIF orientation tag, as phone
/// photos often are.
enum ReplayExample {
    struct Photo {
        let name: String
        let data: Data
    }

    static let referenceSize = CGSize(width: 480, height: 360)
    static let frameSize = CGSize(width: 640, height: 480)
    /// The panel's TL, TR, BR, BL in the upright reference, normalized.
    static let corners = [ImagePoint(x: 40 / 480, y: 30 / 360), ImagePoint(x: 440 / 480, y: 30 / 360),
                          ImagePoint(x: 440 / 480, y: 330 / 360), ImagePoint(x: 40 / 480, y: 330 / 360)]
    /// Where the panel lands in each test photo (pixels, y down).
    static let liveCorners = [CGPoint(x: 150, y: 90), CGPoint(x: 505, y: 125),
                              CGPoint(x: 470, y: 400), CGPoint(x: 130, y: 365)]

    static func reference() -> Photo {
        Photo(name: "Example reference", data: encode(panelImage(), orientation: .up))
    }

    static func testPhotos() -> [Photo] {
        let view = scene(covered: false)
        return [
            Photo(name: "1 · Angled", data: encode(view, orientation: .up)),
            Photo(name: "2 · Mostly covered", data: encode(scene(covered: true), orientation: .up)),
            Photo(name: "3 · Clear again (stored rotated)", data: encode(view, orientation: .right)),
        ]
    }

    // MARK: - Drawing

    private static let context = CIContext()

    /// Label-like clutter: many small high-contrast blocks on a mid-grey face.
    private static func texture(size: CGSize, seed: UInt64) -> CIImage {
        var random = SplitMix64(seed: seed)
        var image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
        for _ in 0..<Int(size.width * size.height / 900) {
            let width = CGFloat(random.next(4...28)), height = CGFloat(random.next(4...22))
            let rect = CGRect(x: CGFloat(random.next(0...Int(size.width - width))),
                              y: CGFloat(random.next(0...Int(size.height - height))), width: width, height: height)
            let level = random.next(0...1) == 0 ? Double(random.next(0...60)) / 255 : Double(random.next(195...245)) / 255
            image = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: rect).composited(over: image)
        }
        return image
    }

    private static func panelImage() -> CIImage {
        texture(size: referenceSize, seed: 7)
    }

    /// The panel warped into a different background, optionally mostly hidden.
    private static func scene(covered: Bool) -> CIImage {
        let panelRect = CGRect(x: 40, y: 30, width: 400, height: 300)  // y-down pixels
        // Core Image is y-up: flip both the crop and the destination corners.
        let panel = panelImage().cropped(to: CGRect(x: panelRect.minX, y: referenceSize.height - panelRect.maxY,
                                                    width: panelRect.width, height: panelRect.height))
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = panel.transformed(by: CGAffineTransform(translationX: -panel.extent.minX, y: -panel.extent.minY))
        func up(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: frameSize.height - point.y) }
        warp.topLeft = up(liveCorners[0])
        warp.topRight = up(liveCorners[1])
        warp.bottomRight = up(liveCorners[2])
        warp.bottomLeft = up(liveCorners[3])
        var image = warp.outputImage!.composited(over: texture(size: frameSize, seed: 99))
            .cropped(to: CGRect(origin: .zero, size: frameSize))
        if covered {
            let hand = CGRect(x: 100, y: frameSize.height - 420, width: 430, height: 360)
            image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: hand).composited(over: image)
        }
        return image
    }

    /// Encodes `upright` so that applying `orientation` shows it upright again.
    private static func encode(_ upright: CIImage, orientation: CGImagePropertyOrientation) -> Data {
        let inverse: CGImagePropertyOrientation = switch orientation {
        case .right: .left
        case .left: .right
        default: orientation
        }
        let stored = upright.oriented(inverse)
        let origin = stored.transformed(by: CGAffineTransform(translationX: -stored.extent.minX, y: -stored.extent.minY))
        let image = context.createCGImage(origin, from: origin.extent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
#endif
