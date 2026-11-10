import ContourCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import SurfaceUnderstanding

private let framingSize = PixelSize(width: 720, height: 1280)
private func framingQuad(_ values: [(Double, Double)]) -> PanelQuad {
    let p = values.map { ImagePoint(x: $0.0, y: $0.1) }
    return PanelQuad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
}
private func framingBox(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> PanelQuad {
    framingQuad([(left,top), (right,top), (right,bottom), (left,bottom)])
}

@Test("Framing rules match real upright 720x1280 quads")
func framingRealQuads() {
    let examples: [(PanelFraming.Advice, [(Double, Double)])] = [
        (.ready, [(0.22,0.02),(0.75,0.02),(0.74,0.92),(0.24,0.92)]),
        (.ready, [(0.36,0.18),(0.79,0.18),(0.75,0.87),(0.35,0.87)]),
        (.ready, [(0.09,0.44),(0.77,0.46),(0.78,0.62),(0.08,0.61)]),
        (.moveCloser, [(0.38,0.28),(0.71,0.27),(0.66,0.70),(0.39,0.80)]),
        (.tooAngled, [(0.41,0.12),(0.90,0.11),(0.89,0.84),(0.02,0.87)]),
        (.offCenter(.left), [(0.13,0.05),(0.68,0.38),(0.44,0.47),(-0.17,0.19)])
    ]
    for (expected, points) in examples {
        #expect(PanelFraming().advice(for: framingQuad(points), frame: framingSize) == expected)
    }
    #expect(PanelFraming().advice(for: nil, frame: framingSize) == .noPanel)
    #expect(PanelFraming().advice(for: .fullFrame, frame: framingSize) == .moveBack)
}

@Test("Clipping and centring take priority over moving closer")
func framingDecisionPriority() {
    let examples: [(PanelQuad, PanelFraming.Advice)] = [
        (framingBox(0.01,0.4,0.3,0.6), .offCenter(.left)),
        (framingBox(0.7,0.4,0.99,0.6), .offCenter(.right)),
        (framingBox(0.4,0.01,0.6,0.3), .offCenter(.up)),
        (framingBox(0.4,0.7,0.6,0.99), .offCenter(.down)),
        (framingBox(-0.1,0.3,1.05,0.7), .moveBack),
        (framingBox(0.3,0,0.7,1), .moveBack),
        (framingBox(-0.05,-0.2,0.5,0.5), .offCenter(.up)),
        (framingBox(0.5,0.5,1.2,1.05), .offCenter(.right)),
        (framingBox(0.05,0.4,0.35,0.6), .offCenter(.left)),
        (framingBox(0.65,0.4,0.95,0.6), .offCenter(.right)),
        (framingBox(0.4,0.05,0.6,0.35), .offCenter(.up)),
        (framingBox(0.4,0.65,0.6,0.95), .offCenter(.down)),
        (framingBox(0.2,0.4,0.8,0.6), .ready),
        (framingBox(0.35,0.15,0.65,0.85), .ready)
    ]
    for (quad, expected) in examples {
        #expect(PanelFraming().advice(for: quad, frame: framingSize) == expected)
    }
}

@Test("Perspective compares pixel distances, not normalized distances")
func framingUsesPixelAspectRatio() {
    let quad = framingQuad([(0.2,0.2),(0.8,0.35),(0.65,0.8),(0.4,0.55)])
    #expect(PanelFraming().advice(for: quad, frame: framingSize) == .ready)
    #expect(PanelFraming().advice(for: quad, frame: PixelSize(width: 1280, height: 720)) == .tooAngled)
}

@Test("Invalid framing geometry cannot be ready")
func framingInvalidGeometry() {
    #expect(PanelFraming().advice(for: .fullFrame, frame: PixelSize(width: 0, height: 1280)) == .noPanel)
    #expect(PanelFraming().advice(for: framingBox(.nan,0.3,0.8,0.7), frame: framingSize) == .noPanel)
    #expect(PanelFraming().advice(for: framingBox(0.5,0.5,0.5,0.5), frame: framingSize) == .noPanel)
}

@Test("Framing advice has the agreed spoken prompts")
func framingSpokenAdvice() {
    let examples: [(PanelFraming.Advice, String)] = [
        (.noPanel,"I can't see the panel"), (.moveCloser,"Move closer"),
        (.moveBack,"Move back a little"), (.tooAngled,"Point the phone straight at the panel"),
        (.ready,"Hold still"), (.offCenter(.left),"Move left a little"),
        (.offCenter(.right),"Move right a little"), (.offCenter(.up),"Move up a little"),
        (.offCenter(.down),"Move down a little")
    ]
    for (advice, spoken) in examples { #expect(advice.spoken == spoken) }
}

@Test("Stable throttles checks and requires a full second of ready observations")
func framingStableClock() {
    let start = Date(timeIntervalSince1970: 100)
    var stable = PanelFraming.Stable()
    #expect(stable.isDue(at: start))
    let recorded1 = stable.record(.ready, at: start)
    #expect(!recorded1)
    #expect(!stable.isDue(at: start.addingTimeInterval(0.3)))
    #expect(stable.isDue(at: start.addingTimeInterval(0.5)))
    let recorded2 = stable.record(.ready, at: start.addingTimeInterval(0.5))
    #expect(!recorded2)
    let recorded3 = stable.record(.ready, at: start.addingTimeInterval(1))
    #expect(recorded3)
    let recorded4 = stable.record(.moveCloser, at: start.addingTimeInterval(1.5))
    #expect(!recorded4)
    let recorded5 = stable.record(.ready, at: start.addingTimeInterval(2))
    #expect(!recorded5)
    let recorded6 = stable.record(.ready, at: start.addingTimeInterval(2.5))
    #expect(!recorded6)
    let recorded7 = stable.record(.ready, at: start.addingTimeInterval(3))
    #expect(recorded7)
}

@Test("Every non-ready result resets the hold, and reversed timestamps restart it")
func framingStableReset() {
    let start = Date(timeIntervalSince1970: 100)
    for advice: PanelFraming.Advice in [.noPanel,.moveCloser,.moveBack,.tooAngled,.offCenter(.left)] {
        var stable = PanelFraming.Stable()
        let recorded8 = stable.record(.ready, at: start)
        #expect(!recorded8)
        let recorded9 = stable.record(advice, at: start.addingTimeInterval(0.5))
        #expect(!recorded9)
        let recorded10 = stable.record(.ready, at: start.addingTimeInterval(1))
        #expect(!recorded10)
        let recorded11 = stable.record(.ready, at: start.addingTimeInterval(1.5))
        #expect(!recorded11)
        let recorded12 = stable.record(.ready, at: start.addingTimeInterval(2))
        #expect(recorded12)
        let recorded13 = stable.record(.ready, at: start)
        #expect(!recorded13)
        let recorded14 = stable.record(.ready, at: start)
        #expect(!recorded14)
    }
}

@Test("Generated camera frames produce aiming advice", arguments: [0.8, 0.35, 0.6])
func framingSyntheticImages(width: Double) async throws {
    let fixture = try SyntheticPanel.framedPhoto(width: width, centerX: width == 0.6 ? 0.68 : 0.5)
    let detected = try await PanelDetector().detectPanel(in: fixture.photo).quad
    for (actual, expected) in zip([detected.topLeft,detected.topRight,detected.bottomRight,detected.bottomLeft],
                                  [fixture.quad.topLeft,fixture.quad.topRight,fixture.quad.bottomRight,fixture.quad.bottomLeft]) {
        #expect(abs(actual.x - expected.x) < 0.02)
        #expect(abs(actual.y - expected.y) < 0.02)
    }
    let expected: PanelFraming.Advice = width == 0.8 ? .ready : width == 0.35 ? .moveCloser : .offCenter(.right)
    #expect(await PanelFraming().advice(for: fixture.photo) == expected)
}

@Test("Full-frame and undecodable photos give safe framing advice")
func framingPhotoFallbacks() async throws {
    let fullFrame = try SyntheticPanel.photo()
    #expect(await PanelFraming().advice(for: fullFrame) == .moveBack)
    let bad = PanelPhoto(data: Data(), pixelSize: framingSize, timestamp: .now)
    #expect(await PanelFraming().advice(for: bad) == .noPanel)
}

@Test("Photo orientation uses the upright frame dimensions and directions")
func framingPhotoOrientation() async throws {
    var photo = try SyntheticPanel.framedPhoto(width: 0.6, centerX: 0.68).photo
    for (orientation, expected): (PhotoOrientation, PanelFraming.Advice) in [
        (.up,.offCenter(.right)), (.down,.offCenter(.left)),
        (.right,.offCenter(.down)), (.left,.offCenter(.up))
    ] {
        photo.orientation = orientation
        #expect(await PanelFraming().advice(for: photo) == expected)
    }
}

@Test("A camera-format BGRA buffer uses the TIFF framing path")
func framingPixelBuffer() async throws {
    let photo = try SyntheticPanel.framedPhoto(width: 0.8).photo
    let image = try photo.cgImage()
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                               [kCVPixelBufferCGImageCompatibilityKey: true,
                                kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    #expect(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
    do {
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    #expect(await PanelFraming().advice(for: pixels, orientation: .up) == .ready)
    for orientation: CGImagePropertyOrientation in [.upMirrored,.downMirrored,.leftMirrored,.rightMirrored] {
        #expect(await PanelFraming().advice(for: pixels, orientation: orientation) == .noPanel)
    }
}
