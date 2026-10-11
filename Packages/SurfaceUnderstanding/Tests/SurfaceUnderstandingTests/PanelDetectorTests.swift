import ContourCore
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import Testing
@testable import SurfaceUnderstanding

@Test("Panel detection runs in under 2 seconds on the synthetic panel")
func panelDetectorIsFast() async throws {
    let photo = try SyntheticPanel.photo()
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
        _ = try await PanelDetector().detectPanel(in: photo)
    }
    print("PanelDetector synthetic 900x600: \(elapsed)")
    #expect(elapsed < .seconds(2))
}

@Test func projectiveMapping() {
    // Independent forward homography: x=(.6u+.1v+.1)/(.2u+.1v+1).
    func source(_ u: Double, _ v: Double) -> ImagePoint {
        ImagePoint(x: (0.6*u + 0.1*v + 0.1)/(0.2*u + 0.1*v + 1),
                   y: (0.1*u + 0.7*v + 0.1)/(0.2*u + 0.1*v + 1))
    }
    let quad = PanelQuad(topLeft: source(0,0), topRight: source(1,0),
                         bottomRight: source(1,1), bottomLeft: source(0,1))
    for (u,v) in [(0.0,0.0),(1,0),(1,1),(0,1),(0.5,0.5),(-0.2,1.3)] {
        let result = PanelDetector().rectify(source(u,v), within: quad)
        #expect(abs(result.x-u) < 1e-9)
        #expect(abs(result.y-v) < 1e-9)
    }
}
@Test func degenerateQuadDoesNotCrash() {
    let p = ImagePoint(x: 0.5, y: 0.5)
    let q = PanelQuad(topLeft:p, topRight:p, bottomRight:p, bottomLeft:p)
    #expect(PanelDetector().rectify(p, within:q).x.isNaN)
}
@Test func undecodablePhoto() async {
    let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width:0,height:0), timestamp:Date())
    do {
        _ = try await PanelDetector().detect(photo)
        Issue.record("Expected an undecodable-image error")
    } catch { #expect(error as? SurfaceUnderstandingError == .undecodableImage) }
}

@Test func expansionIncludesKeypadAndDisplayButNotDistantText() {
    let detector = PanelDetector()
    let seed = PanelQuad(topLeft: ImagePoint(x:0.3,y:0.3), topRight: ImagePoint(x:0.6,y:0.2),
                         bottomRight: ImagePoint(x:0.7,y:0.5), bottomLeft: ImagePoint(x:0.4,y:0.6))
    func source(_ u: Double, _ v: Double) -> ImagePoint {
        ImagePoint(x:0.3 + 0.3*u + 0.1*v, y:0.3 - 0.1*u + 0.3*v)
    }
    func box(_ u: Double, _ v: Double, _ w: Double, _ h: Double) -> [ImagePoint] {
        [source(u,v),source(u+w,v),source(u+w,v+h),source(u,v+h)]
    }
    let controls = [box(0.1,0.1,0.2,0.1),box(0.4,0.1,0.2,0.1),box(0.7,0.1,0.2,0.1),
                    box(0.1,1.2,0.2,0.1),box(0.7,1.7,0.2,0.1),box(0.2,-0.6,0.6,0.2)]
    let expanded = detector.enclosingControls(seed:seed, evidence:controls + [box(2,1,0.2,0.1)])
    for point in controls.flatMap({$0}) {
        #expect(detector.rectify(point, within:expanded).isOnPanel)
    }
    #expect(!detector.rectify(source(2,1), within:expanded).isOnPanel)
}
@Test func emptyEvidencePreservesSeed() {
    #expect(PanelDetector().enclosingControls(seed: .fullFrame, evidence: []) == .fullFrame)
}

@Test func completePanelDoesNotExpandToLogo() {
    func box(_ x:Double,_ y:Double,_ w:Double,_ h:Double)->[ImagePoint] {
        [ImagePoint(x:x,y:y),ImagePoint(x:x+w,y:y),ImagePoint(x:x+w,y:y+h),ImagePoint(x:x,y:y+h)]
    }
    let display = box(0.35,0.2,0.3,0.2)
    let labels = [box(0.05,0.2,0.15,0.08),box(0.75,0.2,0.15,0.08),box(0.4,0.7,0.15,0.08),display,box(0.3,1.2,0.4,0.3)]
    #expect(PanelDetector().enclosingControls(seed:.fullFrame, evidence:labels, displays:[display]) == .fullFrame)
}

@Test func cropReviewWarnings() {
    let detector = PanelDetector()
    #expect(detector.cropWarnings(quad:.fullFrame, estimatedAlignment:false).isEmpty)
    #expect(detector.cropWarnings(quad:.fullFrame, estimatedAlignment:true).count == 1)
    let clipped = PanelQuad(topLeft:ImagePoint(x:0,y:-0.1),topRight:ImagePoint(x:1,y:-0.1),
                            bottomRight:ImagePoint(x:1,y:1),bottomLeft:ImagePoint(x:0,y:1))
    #expect(detector.cropWarnings(quad:clipped, estimatedAlignment:false).count == 1)
    #expect(detector.cropWarnings(quad:clipped, estimatedAlignment:true).count == 2)
}

@Test func ocrFailurePreservesRectangleWithWarning() throws {
    let result = try PanelDetector().refinePanel(seed:.fullFrame, confidence:0.9) {
        throw NSError(domain:"OCRTest", code:1)
    }
    #expect(result.quad == .fullFrame)
    #expect(result.confidence == 0.9)
    #expect(!result.estimatedAlignment)
    #expect(result.warnings.count == 1)
}
@Test func ocrCancellationDoesNotBecomeFallback() {
    for failure: any Error in [CancellationError(), SurfaceUnderstandingError.cancelled] {
        do {
            _ = try PanelDetector().refinePanel(seed:.fullFrame, confidence:1) { throw failure }
            Issue.record("Cancellation must propagate")
        } catch { #expect(error as? SurfaceUnderstandingError == .cancelled) }
    }
}
@Test func successfulEmptyOcrDoesNotReportFailure() throws {
    let result = try PanelDetector().refinePanel(seed:.fullFrame, confidence:1) { ([],[]) }
    #expect(result.quad == .fullFrame)
    #expect(result.warnings.isEmpty)
}

@Test("Text expansion is opt-in")
func panelTextExpansionIsOptIn() {
    #expect(!PanelDetector().expandWithText)
    #expect(PanelDetector(expandWithText: true).expandWithText)
}

@Test("A structured full-frame panel uses the whole image", arguments: [PhotoOrientation.up, .right])
func panelFullFrameFallback(orientation: PhotoOrientation) async throws {
    let result = try await PanelDetector().detectPanel(in: SyntheticPanel.photo(orientation: orientation))
    #expect(result.quad == .fullFrame)
    #expect(result.confidence == 0.6)
}

// Unlabelled generated images avoid depending on OCR or external photo files.
private func panelRectanglePhoto(_ rectangles: [CGRect]) throws -> PanelPhoto {
    let context = try #require(CGContext(data: nil, width: 900, height: 600,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    for rectangle in rectangles { context.fill(rectangle) }
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return PanelPhoto(data: data as Data, pixelSize: PixelSize(width: 900, height: 600), timestamp: .now)
}

@Test("A blank wall is not a panel")
func panelRejectsBlankWall() async throws {
    let photo = try panelRectanglePhoto([])
    await #expect(throws: SurfaceUnderstandingError.noPanelFound) {
        _ = try await PanelDetector().detectPanel(in: photo)
    }
}

@Test("A lone small rectangle is insufficient evidence for a full-frame panel")
func panelPreservesIsolatedSmallRectangle() async throws {
    let photo = try panelRectanglePhoto([CGRect(x: 300, y: 220, width: 180, height: 120)])
    let result = try await PanelDetector().detectPanel(in: photo)
    #expect(result.quad != .fullFrame)
    #expect(abs(result.quad.topLeft.x - 300.0 / 900) < 0.02)
    #expect(abs(result.quad.bottomRight.x - 480.0 / 900) < 0.02)
    #expect(result.confidence >= 0.7)
}

@Test("Default detection preserves a large rectangle and its Vision confidence")
func panelPreservesLargeRectangle() async throws {
    let photo = try panelRectanglePhoto([CGRect(x: 150, y: 100, width: 600, height: 400)])
    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 10
    request.minimumConfidence = 0.7
    request.minimumAspectRatio = 0.1
    request.maximumAspectRatio = 1
    request.minimumSize = 0.1
    request.quadratureTolerance = 45
    try VNImageRequestHandler(cgImage: photo.cgImage()).perform([request])
    let seed = try #require(request.results?.first)
    let result = try await PanelDetector().detectPanel(in: photo)
    #expect(result.quad != .fullFrame)
    #expect(abs(result.quad.topLeft.x - 1.0 / 6) < 0.02)
    #expect(abs(result.quad.topLeft.y - 1.0 / 6) < 0.02)
    #expect(abs(result.quad.bottomRight.x - 5.0 / 6) < 0.02)
    #expect(abs(result.quad.bottomRight.y - 5.0 / 6) < 0.02)
    #expect(result.confidence == Double(seed.confidence))
}

@Test("Cancelled panel detection stops before decoding")
func panelDetectionCancellation() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 1, height: 1), timestamp: .now)
        return try await PanelDetector().detectPanel(in: photo)
    }
    await #expect(throws: SurfaceUnderstandingError.cancelled) { _ = try await task.value }
}
