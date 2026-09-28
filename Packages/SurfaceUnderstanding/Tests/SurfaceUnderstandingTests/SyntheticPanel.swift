//
//  SyntheticPanel.swift
//  SurfaceUnderstandingTests
//
//  A fake microwave panel drawn with CoreGraphics, so every lane has a photo to
//  run against before the real test set exists — and so CI never depends on a
//  JPEG someone forgot to commit.
//
//  Layout (matches `MockSurfaceMaps.microwave` so the two can be compared):
//  dark panel, six light buttons in a 3×2 grid, each with its label printed on
//  it. Bounds are in normalized panel space, y down, exactly like the mock.
//

import ContourCore
import ContourMocks
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SyntheticPanel {

    /// Pixel size of the generated photo.
    static let size = PixelSize(width: 900, height: 600)

    /// The answer key: what a perfect detector should return for `photo()`.
    static var expected: SurfaceMap { MockSurfaceMaps.microwave }

    /// A JPEG-encoded `PanelPhoto` of the panel, filling the whole frame.
    ///
    /// Because the panel *is* the frame, the correct quad is
    /// `PanelQuad.fullFrame` and button bounds equal the mock's bounds.
    static func photo(orientation: PhotoOrientation = .up) throws -> PanelPhoto {
        let image = try render()
        let data = try encodeJPEG(image)
        return PanelPhoto(
            data: data,
            pixelSize: size,
            orientation: orientation,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Drawing

    private static func render() throws -> CGImage {
        let w = size.width, h = size.height
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw SurfaceUnderstandingError.underlying("no context") }

        // CoreGraphics is y-UP. Flip once so we can draw in y-DOWN panel space
        // and have it land where the mock says it lands.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Panel background.
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        for button in expected.buttons {
            let r = button.bounds
            let rect = CGRect(
                x: r.minX * Double(w), y: r.minY * Double(h),
                width: r.width * Double(w), height: r.height * Double(h)
            )
            ctx.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1))
            ctx.fill(rect)

            if let label = button.label {
                draw(label, centeredIn: rect, in: ctx)
            }
        }

        guard let image = ctx.makeImage() else {
            throw SurfaceUnderstandingError.underlying("no image")
        }
        return image
    }

    private static func draw(_ text: String, centeredIn rect: CGRect, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // Text is drawn y-up; undo the flip locally so glyphs are not mirrored.
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - bounds.width / 2, y: rect.midY + bounds.height / 2 - bounds.origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw SurfaceUnderstandingError.underlying("no destination") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SurfaceUnderstandingError.underlying("encode failed")
        }
        return out as Data
    }
}
