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

    /// The same panel, but smaller and sitting inside a larger dark photo, as if
    /// shot from further back. The panel no longer fills the frame, so the
    /// correct quad is `quad`, not `.fullFrame`. Button bounds are unchanged:
    /// they are in panel space.
    static func insetPhoto() throws -> (photo: PanelPhoto, quad: PanelQuad) {
        let canvas = PixelSize(width: 1500, height: 1100)
        let panelRect = CGRect(x: 330, y: 240, width: size.width, height: size.height)

        let ctx = try context(canvas, background: CGColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1))
        ctx.draw(try render(), in: panelRect)
        let image = try makeImage(ctx)

        // `panelRect` is in y-up canvas pixels; corners are y-down fractions.
        func corner(_ x: CGFloat, _ yUp: CGFloat) -> ImagePoint {
            ImagePoint(x: Double(x) / Double(canvas.width), y: 1 - Double(yUp) / Double(canvas.height))
        }
        let quad = PanelQuad(
            topLeft: corner(panelRect.minX, panelRect.maxY),
            topRight: corner(panelRect.maxX, panelRect.maxY),
            bottomRight: corner(panelRect.maxX, panelRect.minY),
            bottomLeft: corner(panelRect.minX, panelRect.minY)
        )
        return (try photo(image, size: canvas), quad)
    }
    
    /// The inset panel with bright rectangles outside the panel.
    /// The detector should ignore those rectangles and only find buttons
    /// inside the supplied panel quad.
    static func insetPhotoWithClutter() throws -> (photo: PanelPhoto, quad: PanelQuad) {
        let canvas = PixelSize(width: 1500, height: 1100)
        let panelRect = CGRect(x: 330, y: 240, width: size.width, height: size.height)

        let ctx = try context(
            canvas,
            background: CGColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
        )

        ctx.draw(try render(), in: panelRect)

        ctx.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1))

        ctx.fill(CGRect(x: 60, y: 80, width: 180, height: 100))
        ctx.fill(CGRect(x: 1180, y: 100, width: 220, height: 120))
        ctx.fill(CGRect(x: 80, y: 850, width: 200, height: 110))
        ctx.fill(CGRect(x: 1200, y: 820, width: 180, height: 140))

        let image = try makeImage(ctx)

        func corner(_ x: CGFloat, _ yUp: CGFloat) -> ImagePoint {
            ImagePoint(
                x: Double(x) / Double(canvas.width),
                y: 1 - Double(yUp) / Double(canvas.height)
            )
        }

        let quad = PanelQuad(
            topLeft: corner(panelRect.minX, panelRect.maxY),
            topRight: corner(panelRect.maxX, panelRect.maxY),
            bottomRight: corner(panelRect.maxX, panelRect.minY),
            bottomLeft: corner(panelRect.minX, panelRect.minY)
        )

        return (try photo(image, size: canvas), quad)
    }

    /// Three labels on one continuous light strip, 20 px apart. Vision reads
    /// them as a single line ("Popcorn Beverage Defrost"), which is what a
    /// membrane keypad does too. The regions split the strip halfway between
    /// neighbouring labels; the panel fills the frame.
    static func tightRowPhoto() throws -> (photo: PanelPhoto, regions: [PanelRect], labels: [String]) {
        let labels = ["Popcorn", "Beverage", "Defrost"]
        let gap: CGFloat = 20
        let widths = labels.map { CTLineGetBoundsWithOptions(line($0), []).width }
        let total = widths.reduce(0, +) + gap * CGFloat(labels.count - 1)
        let y: CGFloat = 270, h: CGFloat = 60

        // Each label's own column, then widen to meet the neighbours halfway.
        var x = (CGFloat(size.width) - total) / 2
        var columns: [CGRect] = []
        for width in widths {
            columns.append(CGRect(x: x, y: y, width: width, height: h))
            x += width + gap
        }
        let cells = columns.indices.map { i -> CGRect in
            let left = i == 0 ? columns[i].minX - 40 : (columns[i - 1].maxX + columns[i].minX) / 2
            let right = i == columns.count - 1 ? columns[i].maxX + 40 : (columns[i].maxX + columns[i + 1].minX) / 2
            return CGRect(x: left, y: y, width: right - left, height: h)
        }

        let strip = cells.first!.union(cells.last!)
        let image = try render(buttons: zip(cells, labels).map { ($0, $1) }, strip: strip)
        let regions = cells.map {
            PanelRect(
                x: Double($0.minX) / Double(size.width), y: Double($0.minY) / Double(size.height),
                width: Double($0.width) / Double(size.width), height: Double($0.height) / Double(size.height)
            )
        }
        return (try photo(image, size: size), regions, labels)
    }

    /// Four keys sitting on a raised plate, plus two loose keys beside it.
    /// Vision finds the plate as a rectangle too, with the same confidence as
    /// the keys, so a "keep the bigger box" rule would return the plate and
    /// lose the four keys on it. Returns the six keys in panel space; the panel
    /// fills the frame.
    static func groupedKeysPhoto() throws -> (photo: PanelPhoto, keys: [PanelRect]) {
        let ctx = try context(size, background: CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)

        let w = CGFloat(size.width), h = CGFloat(size.height)
        let plate = CGRect(x: 0.08 * w, y: 0.15 * h, width: 0.40 * w, height: 0.44 * h)
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        ctx.fill(plate)

        let gap: CGFloat = 18
        let keyWidth = (plate.width - 3 * gap) / 2
        let keyHeight = (plate.height - 3 * gap) / 2
        var keys: [CGRect] = []
        for row in 0..<2 {
            for column in 0..<2 {
                keys.append(CGRect(
                    x: plate.minX + gap + CGFloat(column) * (keyWidth + gap),
                    y: plate.minY + gap + CGFloat(row) * (keyHeight + gap),
                    width: keyWidth, height: keyHeight
                ))
            }
        }
        for x in [0.60, 0.78] {
            keys.append(CGRect(x: x * w, y: 0.30 * h, width: 0.14 * w, height: 0.16 * h))
        }

        ctx.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1))
        keys.forEach { ctx.fill($0) }

        let rects = keys.map {
            PanelRect(
                x: Double($0.minX / w), y: Double($0.minY / h),
                width: Double($0.width / w), height: Double($0.height / h)
            )
        }
        return (try photo(try makeImage(ctx), size: size), rects)
    }
    
    static func duplicateLabelPhoto() throws -> (photo: PanelPhoto, key: PanelRect) {
        let ctx = try context(
            size,
            background: CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        )

        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)

        let key = CGRect(
            x: 0.30 * CGFloat(size.width),
            y: 0.30 * CGFloat(size.height),
            width: 0.40 * CGFloat(size.width),
            height: 0.30 * CGFloat(size.height)
        )

        ctx.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1))
        ctx.fill(key)

        ctx.setFillColor(CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1))
        ctx.fill(CGRect(
            x: key.minX + 70,
            y: key.minY + 35,
            width: key.width - 140,
            height: 50
        ))

        ctx.fill(CGRect(
            x: key.minX + 80,
            y: key.minY + 40,
            width: key.width - 160,
            height: 40
        ))

        let keyRect = PanelRect(
            x: Double(key.minX / CGFloat(size.width)),
            y: Double(key.minY / CGFloat(size.height)),
            width: Double(key.width / CGFloat(size.width)),
            height: Double(key.height / CGFloat(size.height))
        )

        let image = try makeImage(ctx)

        return (try photo(image, size: size), keyRect)
    }

    static func halfOverlappingPhoto() throws -> (photo: PanelPhoto, key: PanelRect) {
        let ctx = try context(
            size,
            background: CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        )

        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)

        let key = CGRect(
            x: 0.25 * CGFloat(size.width),
            y: 0.30 * CGFloat(size.height),
            width: 0.30 * CGFloat(size.width),
            height: 0.30 * CGFloat(size.height)
        )

        ctx.setFillColor(CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1))
        ctx.fill(key)

        let overlapping = CGRect(
            x: key.midX,
            y: key.minY - 20,
            width: key.width * 0.8,
            height: key.height + 40
        )

        ctx.setStrokeColor(CGColor(red: 0.40, green: 0.40, blue: 0.40, alpha: 1))
        ctx.setLineWidth(8)
        ctx.stroke(overlapping)

        let panelRect = PanelRect(
            x: Double(key.minX / CGFloat(size.width)),
            y: Double(key.minY / CGFloat(size.height)),
            width: Double(key.width / CGFloat(size.width)),
            height: Double(key.height / CGFloat(size.height))
        )

        return (
            try photo(try makeImage(ctx), size: size),
            panelRect
        )
    }
    
    // MARK: - Drawing

    private static func render() throws -> CGImage {
        let buttons = expected.buttons.map { button -> (CGRect, String?) in
            let r = button.bounds
            let rect = CGRect(
                x: r.minX * Double(size.width), y: r.minY * Double(size.height),
                width: r.width * Double(size.width), height: r.height * Double(size.height)
            )
            return (rect, button.label)
        }
        return try render(buttons: buttons, strip: nil)
    }

    /// Draws a panel at `size`. `buttons` and `strip` are in y-down panel
    /// pixels. With a `strip`, the buttons share one continuous light surface
    /// instead of each getting their own.
    private static func render(buttons: [(CGRect, String?)], strip: CGRect?) throws -> CGImage {
        let ctx = try context(size, background: CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))

        // CoreGraphics is y-UP. Flip once so we can draw in y-DOWN panel space
        // and have it land where the mock says it lands.
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)

        let light = CGColor(red: 0.88, green: 0.88, blue: 0.86, alpha: 1)
        if let strip {
            ctx.setFillColor(light)
            ctx.fill(strip)
        }
        for (rect, label) in buttons {
            if strip == nil {
                ctx.setFillColor(light)
                ctx.fill(rect)
            }
            if let label {
                draw(label, centeredIn: rect, in: ctx)
            }
        }
        return try makeImage(ctx)
    }

    private static func context(_ size: PixelSize, background: CGColor) throws -> CGContext {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw SurfaceUnderstandingError.underlying("no context") }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return ctx
    }

    private static func makeImage(_ ctx: CGContext) throws -> CGImage {
        guard let image = ctx.makeImage() else {
            throw SurfaceUnderstandingError.underlying("no image")
        }
        return image
    }

    private static func photo(_ image: CGImage, size: PixelSize) throws -> PanelPhoto {
        PanelPhoto(
            data: try encodeJPEG(image),
            pixelSize: size,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private static func line(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private static func draw(_ text: String, centeredIn rect: CGRect, in ctx: CGContext) {
        let line = line(text)
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
