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
// The quad half of LiveSurfaceUnderstanding is real; buttons and labels are not.
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

@Test("a panel-shaped image returns the real quad, the photo's id, and no buttons")
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

    // Buttons are still pending, and an empty map is a success, not a failure.
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
