import ContourCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import SurfaceUnderstanding

@Test("Probe: a fully visible inset panel should keep its outer edges")
func probeSmallInsetPanel() async throws {
    let context = try #require(CGContext(data: nil, width: 900, height: 600,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 250, y: 160, width: 400, height: 270))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    for x in [270, 400, 530] {
        for y in [180, 280] { context.fill(CGRect(x: x, y: y, width: 100, height: 70)) }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    try (data as Data).write(to: URL(fileURLWithPath: "/tmp/contour-surface-inset-panel.png"))
    let rectangles = VNDetectRectanglesRequest()
    rectangles.maximumObservations = 10
    rectangles.minimumConfidence = 0.7
    rectangles.minimumAspectRatio = 0.1
    rectangles.maximumAspectRatio = 1
    rectangles.minimumSize = 0.1
    rectangles.quadratureTolerance = 45
    try VNImageRequestHandler(cgImage: image).perform([rectangles])
    print("Inset panel probe: Vision rectangles=\(rectangles.results?.count ?? 0)")
    let photo = PanelPhoto(data: data as Data, pixelSize: PixelSize(width: 900, height: 600), timestamp: Date())
    let result = try await PanelDetector().detectPanel(in: photo)
    print("Inset panel probe: returned quad=\(result.quad) confidence=\(result.confidence)")
    #expect(result.quad != .fullFrame)
}
