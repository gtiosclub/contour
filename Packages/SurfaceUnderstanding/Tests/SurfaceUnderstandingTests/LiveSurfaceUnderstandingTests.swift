//
//  LiveSurfaceUnderstandingTests.swift
//  SurfaceUnderstandingTests
//
//  Failure paths and the real quad for LiveSurfaceUnderstanding.
//

import ContourCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SurfaceUnderstanding

// MARK: - LiveSurfaceUnderstanding
//
// What these pin is that the failure paths THROW rather than trap. A crash here
// would take the app down on a bad frame, and bad frames are the normal case for
// someone aiming a camera they cannot see.
//
// Test images are drawn with CoreGraphics so there are no fixture files to
// commit and nothing to keep in sync.

/// A PNG built in memory, so the test owns its input end to end.
private func pngData(
    width: Int,
    height: Int,
    draw: (CGContext) -> Void
) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    draw(context)

    let image = try #require(context.makeImage())
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        buffer, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return buffer as Data
}

private func photo(_ data: Data, width: Int = 240, height: Int = 240) -> PanelPhoto {
    PanelPhoto(
        data: data,
        pixelSize: PixelSize(width: width, height: height),
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

@Test("garbage bytes throw undecodableImage rather than trapping")
func garbageBytesThrow() async throws {
    let junk = photo(Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0x42, 0x42]))

    await #expect(throws: SurfaceUnderstandingError.undecodableImage) {
        _ = try await LiveSurfaceUnderstanding().detectPanel(from: junk)
    }
}

@Test("an empty PanelPhoto throws undecodableImage rather than trapping")
func emptyDataThrows() async throws {
    await #expect(throws: SurfaceUnderstandingError.undecodableImage) {
        _ = try await LiveSurfaceUnderstanding().detectPanel(from: photo(Data()))
    }
}

@Test("a blank image with no panel in it throws noPanelFound")
func blankImageThrowsNoPanelFound() async throws {
    // Uniform grey: decodes fine, contains no edges, so nothing panel-shaped.
    let blank = try pngData(width: 240, height: 240) { context in
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
    }

    await #expect(throws: SurfaceUnderstandingError.noPanelFound) {
        _ = try await LiveSurfaceUnderstanding().detectPanel(from: photo(blank))
    }
}

@Test("a plain panel returns the real quad, the photo's id, and no buttons",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func panelShapedImageReturnsRealQuad() async throws {
    // A bright rectangle on a dark field: the simplest thing Vision will call a
    // panel. Inset so the quad has to come back as something other than
    // fullFrame — otherwise this test would pass on a hardcoded default.
    let side = 400.0
    let panel = CGRect(x: 80, y: 120, width: 240, height: 160)
    let image = try pngData(width: Int(side), height: Int(side)) { context in
        context.setFillColor(gray: 0.05, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(gray: 0.95, alpha: 1)
        context.fill(panel)
    }

    let subject = photo(image, width: Int(side), height: Int(side))
    let detection = try await LiveSurfaceUnderstanding().detectPanel(from: subject)

    // The contract: echo the photo's identity so PanelReference can pair them.
    #expect(detection.referencePhotoID == subject.id)
    #expect((try? PanelReference(photo: subject, detection: detection)) != nil,
            "the app must be able to build a PanelReference from this")

    // Nothing on this panel looks like a button or reads as a label, and an
    // empty map is a success, not a failure. Text recognition still runs, in
    // case it's a flat keypad, so this is skipped on CI.
    #expect(detection.map.buttons.isEmpty)
    #expect(detection.map.confidence > 0, "panel confidence should carry through")

    // The quad is real: on the panel, not the whole frame, and not degenerate.
    let quad = detection.quad
    let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
    #expect(corners.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(corners.allSatisfy { (-0.05...1.05).contains($0.x) && (-0.05...1.05).contains($0.y) })
    #expect(quad != .fullFrame, "an inset panel must not come back as the full frame")

    let width = quad.topRight.x - quad.topLeft.x
    let height = quad.bottomLeft.y - quad.topLeft.y
    #expect(width > 0.2, "quad should span a real fraction of the image")
    #expect(height > 0.1)
}

@Test("the synthetic microwave comes back with all six buttons and their labels",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func fullPipelineReadsTheMicrowave() async throws {
    let subject = try SyntheticPanel.photo()

    let detection = try await LiveSurfaceUnderstanding().detectPanel(from: subject)

    #expect(detection.referencePhotoID == subject.id)
    let expected = SyntheticPanel.expected.buttons
    #expect(detection.map.buttons.count == expected.count)

    // Every key the mock lists is covered by exactly one found button, and that
    // button reads (close to) the right label.
    for key in expected {
        let hits = detection.map.buttons.filter { $0.bounds.contains(key.bounds.center) }
        #expect(hits.count == 1, "\(key.label ?? "?") is covered by \(hits.count) buttons")
        if let hit = hits.first {
            #expect(TextRecognitionCheck.labelsMatch([hit.label], [key.label]),
                    "read \(hit.label ?? "nil") for \(key.label ?? "nil")")
        }
    }
}

@Test("a label printed under its key goes to that key",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func labelUnderKeyGoesToTheKey() async throws {
    let (subject, keys, labels) = try SyntheticPanel.labelsUnderKeysPhoto()

    let detection = try await LiveSurfaceUnderstanding().detectPanel(from: subject)

    for (key, label) in zip(keys, labels) {
        let hit = detection.map.buttons.first { $0.bounds.contains(key.center) }
        #expect(TextRecognitionCheck.labelsMatch([hit?.label], [label]),
                "the key above \(label) read \(hit?.label ?? "nothing")")
    }
}

@Test("a flat keypad with printed labels and no key outlines gets a button per label",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func printedLabelsBecomeButtons() async throws {
    let (subject, labels) = try SyntheticPanel.printedKeypadPhoto()

    let detection = try await LiveSurfaceUnderstanding().detectPanel(from: subject)

    for label in labels {
        let hits = detection.map.buttons.filter { TextRecognitionCheck.labelsMatch([$0.label], [label]) }
        #expect(hits.count == 1, "\(label): \(hits.count) buttons, map was \(detection.map.buttons.map(\.label))")
    }
}

@Test("Printed buttons stay on the panel, with slack for real edge labels")
func printedButtonsStayOnPanel() {
    let cases: [(String, Double, Double, Double, Double)] = [
        ("Delay Start", 2.28, 0.85, 0.28, 0.47),
        ("Start Pause", 1.31, 0.19, 0.43, 0.46),
        ("START", 0.12, 3.75, 0.20, 0.08),
        ("CANCEL STOP", 2.78, 0.87, 0.24, 0.04),
        ("Unlock", 0.56, 1.02, 0.21, 0.06),
        ("START CANCEL", 0.87, 0.17, 0.22, 0.11)
    ]
    let input = cases.map { label, x, y, width, height in
        (label: label, bounds: PanelRect(x: x - width / 2, y: y - height / 2, width: width, height: height))
    }
    let buttons = LiveSurfaceUnderstanding.printedButtons(from: input)
    #expect(buttons.map(\.label) == ["Unlock", "START CANCEL"])
    #expect(buttons.map(\.bounds) == Array(input.suffix(2)).map(\.bounds))
    #expect(buttons.allSatisfy { $0.confidence == 0.5 })
    // Boundaries are inclusive; the centre, not the whole box, is checked.
    let edges = [-0.05, 1.05].flatMap { value in
        [(label: "x edge", bounds: PanelRect(x: value, y: 0.5, width: 0, height: 0)),
         (label: "y edge", bounds: PanelRect(x: 0.5, y: value, width: 0, height: 0))]
    }
    #expect(LiveSurfaceUnderstanding.printedButtons(from: edges).count == 4)
    let outside = [-0.051, 1.051].flatMap { value in
        [(label: "x off", bounds: PanelRect(x: value, y: 0.5, width: 0, height: 0)),
         (label: "y off", bounds: PanelRect(x: 0.5, y: value, width: 0, height: 0))]
    }
    #expect(LiveSurfaceUnderstanding.printedButtons(from: outside).isEmpty)
}

// MARK: - 2x crop for LabelReader

@Test("a 720x1280 photo with no panel quad is doubled whole")
func smallPhotoIsDoubled() throws {
    let small = photo(try pngData(width: 720, height: 1280) { _ in }, width: 720, height: 1280)
    let input = try #require(LiveSurfaceUnderstanding.labelInput(for: small, panel: .fullFrame))
    #expect(input.image.width == 1440 && input.image.height == 2560)
    #expect(input.panel == .fullFrame)
}

@Test("a 1080x1920 photo is read as it is")
func largePhotoIsUnchanged() throws {
    let large = photo(try pngData(width: 1080, height: 1920) { _ in }, width: 1080, height: 1920)
    #expect(LiveSurfaceUnderstanding.labelInput(for: large, panel: .fullFrame) == nil)
}

@Test("a small photo's panel is cropped out and doubled")
func panelIsCroppedAndDoubled() throws {
    let small = photo(try pngData(width: 720, height: 1280) { _ in }, width: 720, height: 1280)
    let middle = PanelQuad(topLeft: ImagePoint(x: 0.25, y: 0.25), topRight: ImagePoint(x: 0.75, y: 0.25),
                           bottomRight: ImagePoint(x: 0.75, y: 0.75), bottomLeft: ImagePoint(x: 0.25, y: 0.75))
    let input = try #require(LiveSurfaceUnderstanding.labelInput(for: small, panel: middle))
    // Middle half plus a 5% margin, doubled: about 792x1408.
    #expect(abs(input.image.width - 792) <= 4 && abs(input.image.height - 1408) <= 4)
    #expect(input.panel.topLeft.x > 0 && input.panel.topLeft.x < 0.1)
}

@Test("a mark on a .right photo lands on the same panel point after the 2x crop")
func rotatedMarkStaysInPlace() throws {
    // Stored sideways (1280x720, top on the right): white with one black square.
    let data = try pngData(width: 1280, height: 720) { ctx in
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 400, y: 200, width: 30, height: 30))
    }
    let sideways = PanelPhoto(data: data, pixelSize: PixelSize(width: 1280, height: 720),
                              orientation: .right, timestamp: Date(timeIntervalSince1970: 0))
    // A skewed outline, so x and y both get tested.
    let panel = PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.2), topRight: ImagePoint(x: 0.9, y: 0.15),
                          bottomRight: ImagePoint(x: 0.85, y: 0.8), bottomLeft: ImagePoint(x: 0.15, y: 0.85))
    let input = try #require(LiveSurfaceUnderstanding.labelInput(for: sideways, panel: panel))

    let detector = PanelDetector()
    let before = detector.rectify(try darkCenter(sideways.cgImage()), within: panel)
    let after = detector.rectify(try darkCenter(input.image), within: input.panel)
    #expect(abs(before.x - after.x) < 0.01)
    #expect(abs(before.y - after.y) < 0.01)
}

/// Centre of the dark pixels in `image`, normalized, y down.
private func darkCenter(_ image: CGImage) throws -> ImagePoint {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 255, count: w * h * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    try #require(drawn)
    var sx = 0.0, sy = 0.0, n = 0.0
    for y in 0..<h {
        for x in 0..<w where pixels[(y * w + x) * 4] < 128 {
            sx += Double(x); sy += Double(y); n += 1
        }
    }
    try #require(n > 0)
    return ImagePoint(x: (sx / n + 0.5) / Double(w), y: (sy / n + 0.5) / Double(h))
}
