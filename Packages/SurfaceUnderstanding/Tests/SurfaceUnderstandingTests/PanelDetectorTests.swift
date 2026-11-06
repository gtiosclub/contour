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

private func expectPanelCorners(_ actual: PanelQuad, _ expected: PanelQuad) {
    for (a, e) in zip([actual.topLeft, actual.topRight, actual.bottomRight, actual.bottomLeft],
                      [expected.topLeft, expected.topRight, expected.bottomRight, expected.bottomLeft]) {
        #expect(abs(a.x - e.x) < 0.03)
        #expect(abs(a.y - e.y) < 0.03)
    }
}

@Test("Small labelled panels retain their outer corners", arguments: [0.4, 0.5])
func smallPanelRetainsCorners(scale: Double) async throws {
    let fixture = try SyntheticPanel.smallPanelPhoto(scale: scale)
    let result = try await PanelDetector().detectPanel(in: fixture.photo)
    expectPanelCorners(result.quad, fixture.quad)
}

@Test("Keys select the panel instead of the larger door")
func smallPanelBeatsDoor() async throws {
    let fixture = try SyntheticPanel.smallPanelPhoto(scale: 0.4, door: true)
    let result = try await PanelDetector().detectPanel(in: fixture.photo)
    expectPanelCorners(result.quad, fixture.quad)
}

@Test("A fully visible inset panel should keep its outer edges")
func insetPanelRetainsOuterEdges() async throws {
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
    let photo = PanelPhoto(data: data as Data, pixelSize: PixelSize(width: 900, height: 600), timestamp: Date())
    let result = try await PanelDetector().detectPanel(in: photo)
    let expected = PanelQuad(topLeft: ImagePoint(x: 250.0 / 900, y: 170.0 / 600),
                             topRight: ImagePoint(x: 650.0 / 900, y: 170.0 / 600),
                             bottomRight: ImagePoint(x: 650.0 / 900, y: 440.0 / 600),
                             bottomLeft: ImagePoint(x: 250.0 / 900, y: 440.0 / 600))
    expectPanelCorners(result.quad, expected)
}

@Test("A preset group expands to the continuing keypad without distant scene boxes")
func panelKeyGroupIncludesContinuingColumn() {
    let seed = PanelQuad(topLeft: ImagePoint(x: 0.3, y: 0.1), topRight: ImagePoint(x: 0.7, y: 0.1),
                         bottomRight: ImagePoint(x: 0.7, y: 0.4), bottomLeft: ImagePoint(x: 0.3, y: 0.4))
    func box(_ x: Double, _ y: Double) -> [ImagePoint] {
        [(x,y), (x+0.15,y), (x+0.15,y+0.12), (x,y+0.12)].map {
            ImagePoint(x: 0.3 + 0.4 * $0.0, y: 0.1 + 0.3 * $0.1)
        }
    }
    let inside = [box(0.1,0.1), box(0.4,0.1), box(0.7,0.1)]
    let outside = [box(0.1,1.1), box(0.7,1.1), box(0.1,1.5), box(0.7,1.5)]
    let distant = box(2,1.2)
    let detector = PanelDetector()
    let expanded = detector.enclosingKeyGroups(seed: seed, keys: inside + outside + [distant])
    #expect(expanded != seed)
    for point in (inside + outside).flatMap({ $0 }) {
        #expect(detector.rectify(point, within: expanded).isOnPanel)
    }
    #expect(!detector.rectify(distant[0], within: expanded).isOnPanel)
    // A few neighbouring boxes alone must not enlarge a complete panel.
    #expect(detector.enclosingKeyGroups(seed: seed, keys: inside + Array(outside.prefix(3))) == seed)
    #expect(detector.enclosingKeyGroups(seed: seed, keys: inside + Array(repeating: distant, count: 8)) == seed)
}

/// A box's corners in normalized image coordinates.
private func imageBox(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [ImagePoint] {
    [ImagePoint(x: x, y: y), ImagePoint(x: x + width, y: y),
     ImagePoint(x: x + width, y: y + height), ImagePoint(x: x, y: y + height)]
}

private func imageRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PanelQuad {
    let corners = imageBox(x, y, width, height)
    return PanelQuad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
}

private func expectInsidePhoto(_ quad: PanelQuad) {
    for corner in [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft] {
        #expect((-0.02...1.02).contains(corner.x), "corner \(corner) is off the photo")
        #expect((-0.02...1.02).contains(corner.y), "corner \(corner) is off the photo")
    }
}

@Test("A keypad running off the bottom of a close-up never pushes the outline off the photo")
func keyGroupOutlineStaysInsidePhoto() {
    let detector = PanelDetector()
    // A bordered row of presets; the keypad below it continues to the photo's bottom edge.
    let seed = imageRect(0.15, 0.2, 0.7, 0.5)
    let presets = [0.18, 0.41, 0.64].map { imageBox($0, 0.3, 0.18, 0.1) }
    let keypad = [0.72, 0.815, 0.91].flatMap { y in [0.18, 0.41, 0.64].map { imageBox($0, y, 0.18, 0.08) } }
    let outline = detector.enclosingKeyGroups(seed: seed, keys: presets + keypad)
    expectInsidePhoto(outline)
    for point in presets.flatMap({ $0 }) {
        #expect(detector.rectify(point, within: outline).isOnPanel)
    }

    // The same keypad stopping short of the edge still joins the presets.
    let shorter = Array(keypad.prefix(6))
    let grown = detector.enclosingKeyGroups(seed: seed, keys: presets + shorter)
    expectInsidePhoto(grown)
    for point in (presets + shorter).flatMap({ $0 }) {
        #expect(detector.rectify(point, within: grown).isOnPanel)
    }
}

@Test("A few keys do not grow over a door, a handle, a stove strip or a cabinet in their column")
func keyGroupIgnoresNonKeysInItsColumn() {
    // A display and one row of three keys, like a black glass panel with the keypad unlit.
    let seed = imageRect(0.25, 0.2, 0.5, 0.45)
    let keys = [imageBox(0.3, 0.25, 0.4, 0.1)] + [0.32, 0.45, 0.58].map { imageBox($0, 0.55, 0.1, 0.05) }
    let door = imageBox(0.2, 0.68, 0.6, 0.25)                                   // far bigger than a key
    let handle = [0.68, 0.75, 0.82].map { imageBox(0.425, $0, 0.02, 0.06) }     // between the key columns
        + [imageBox(0.385, 0.67, 0.1, 0.05)]
    let stove = [0.32, 0.45, 0.58].map { imageBox($0, 0.88, 0.1, 0.05) }        // key-like, but well below
    let cabinet = [0.32, 0.58].map { imageBox($0, 0.02, 0.1, 0.05) }           // key-like, but well above
    let outline = PanelDetector().enclosingKeyGroups(seed: seed, keys: keys + [door] + handle + stove + cabinet)
    #expect(outline == seed)
}

@Test("A detected rectangle past the photo's edge is clamped onto it")
func rectanglePastPhotoEdgeIsClamped() {
    let detector = PanelDetector()
    let past = PanelQuad(topLeft: ImagePoint(x: 0.01, y: 0.13), topRight: ImagePoint(x: 1.07, y: 0.13),
                         bottomRight: ImagePoint(x: 0.91, y: 0.36), bottomLeft: ImagePoint(x: -0.17, y: 0.35))
    let clamped = detector.clampedToPhoto(past)
    expectInsidePhoto(clamped)
    #expect(clamped.topRight == ImagePoint(x: 1, y: 0.13))
    #expect(clamped.bottomLeft == ImagePoint(x: 0, y: 0.35))
    #expect(clamped.topLeft == past.topLeft)
    // Slightly past the edge is still trackable and is left alone.
    let edge = imageRect(-0.01, 0.2, 1.02, 0.5)
    #expect(detector.clampedToPhoto(edge) == edge)
}

private func wideStripEvidence() -> [PanelQuad] {
    [imageRect(0.35, 0.35, 0.3, 0.08),
     imageRect(0.16, 0.36, 0.07, 0.04), imageRect(0.76, 0.36, 0.07, 0.04),
     imageRect(0.36, 0.45, 0.07, 0.035), imageRect(0.55, 0.45, 0.07, 0.035)]
}

@Test("A borderless wide control bank uses its display and flanking controls")
func wideStripGeometry() throws {
    let detector = PanelDetector()
    let controls = wideStripEvidence()
    let door = imageRect(0.1, 0.65, 0.8, 0.3)
    let sticker = imageRect(0.1, 0.08, 0.15, 0.04)
    let quad = try #require(detector.wideControlStrip(keys: controls + [door, sticker],
                                                   frame: PixelSize(width: 720, height: 1280)))
    for q in controls {
        for p in [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft] {
            #expect(detector.rectify(p, within: quad).isOnPanel)
        }
    }
    #expect(!detector.rectify(door.bottomRight, within: quad).isOnPanel)
    #expect(!detector.rectify(sticker.topLeft, within: quad).isOnPanel)
    #expect(quad != .fullFrame)
    expectInsidePhoto(quad)
}

@Test("Wide fallback rejects one-sided, vertical, nested and invalid evidence")
func wideStripRejectsWeakEvidence() {
    let detector = PanelDetector(), frame = PixelSize(width: 720, height: 1280)
    let keys = wideStripEvidence()
    #expect(detector.wideControlStrip(keys: Array(keys.prefix(1)), frame: frame) == nil)
    #expect(detector.wideControlStrip(keys: keys.enumerated().filter { $0.offset != 1 }.map(\.element), frame: frame) == nil)
    let nested = [keys[0], keys[1], imageRect(0.17, 0.37, 0.02, 0.01), keys[2]]
    #expect(detector.wideControlStrip(keys: nested, frame: frame) == nil)
    let vertical = keys.map { q in
        func p(_ v: ImagePoint) -> ImagePoint { ImagePoint(x: v.y, y: v.x) }
        return PanelQuad(topLeft: p(q.topLeft), topRight: p(q.bottomLeft),
                         bottomRight: p(q.bottomRight), bottomLeft: p(q.topRight))
    }
    #expect(detector.wideControlStrip(keys: vertical, frame: frame) == nil)
    #expect(detector.wideControlStrip(keys: keys, frame: PixelSize(width: 0, height: 0)) == nil)
    #expect(detector.wideControlStrip(keys: [imageRect(.nan, 0, 1, 1)], frame: frame) == nil)
}

@Test("Wide strip padding stays strictly inside the photo")
func wideStripPaddingClamps() throws {
    let keys = [imageRect(0.35, 0.35, 0.3, 0.08), imageRect(-0.01, 0.36, 0.08, 0.04),
                imageRect(0.94, 0.36, 0.08, 0.04), imageRect(0.4, 0.45, 0.07, 0.035)]
    let quad = try #require(PanelDetector().wideControlStrip(keys: keys, frame: PixelSize(width: 720, height: 1280)))
    #expect(quad.topLeft.x == 0)
    #expect(quad.topRight.x == 1)
    for p in [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft] {
        #expect((0...1).contains(p.x) && (0...1).contains(p.y))
    }
}

@Test("Wide panel detection uses controls without an enclosing border", arguments: [false, true])
func wideStripSyntheticPhoto(tilted: Bool) async throws {
    let width = 720, height = 1280
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(CGColor(gray: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if tilted {
        ctx.translateBy(x: 360, y: 640); ctx.rotate(by: 0.07); ctx.translateBy(x: -360, y: -640)
    }
    // No outer panel border: only a display and separate outlined keys.
    for (index, q) in wideStripEvidence().enumerated() {
        let rect = CGRect(x: q.topLeft.x * 720, y: (1 - q.bottomLeft.y) * 1280,
                          width: (q.topRight.x - q.topLeft.x) * 720,
                          height: (q.bottomLeft.y - q.topLeft.y) * 1280)
        if index == 0 { ctx.setFillColor(CGColor(gray: 0.02, alpha: 1)); ctx.fill(rect) }
        else { ctx.setStrokeColor(CGColor(gray: 0.05, alpha: 1)); ctx.setLineWidth(3); ctx.stroke(rect) }
    }
    let bytes = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(bytes, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(dest))
    let photo = PanelPhoto(data: bytes as Data, pixelSize: PixelSize(width: width, height: height), timestamp: .now)
    let result = try await PanelDetector().detectPanel(in: photo)
    #expect(result.quad != .fullFrame)
    expectInsidePhoto(result.quad)
    // Require both sides of the control bank, not just the display.
    #expect(result.quad.topLeft.x < 0.25)
    #expect(result.quad.topRight.x > 0.73)
    #expect(result.quad.bottomLeft.y < 0.6)
}

@Test("A compact display and bank below it provide a laundry panel reference")
func compactControlBank() throws {
    let detector = PanelDetector(), frame = PixelSize(width: 720, height: 1280)
    let display = imageRect(0.3, 0.3, 0.2, 0.06)
    let keys = [0.39, 0.46].flatMap { y in
        [0.22, 0.34, 0.46].map { x in imageRect(x, y, 0.06, 0.025) }
    }
    let quad = try #require(detector.wideControlStrip(keys: [display] + keys, frame: frame))
    for key in keys {
        #expect(detector.rectify(key.topLeft, within: quad).isOnPanel)
        #expect(detector.rectify(key.bottomRight, within: quad).isOnPanel)
    }
    #expect(quad.topLeft.y < display.topLeft.y)
    #expect(quad.bottomRight.y < 0.55)
    #expect(detector.wideControlStrip(keys: [display] + Array(keys.prefix(4)), frame: frame) == nil)
    // A row of text fragments alone cannot establish a two-dimensional bank.
    let row = (0..<6).map { imageRect(0.2 + Double($0) * 0.06, 0.4, 0.04, 0.02) }
    #expect(detector.wideControlStrip(keys: [display] + row, frame: frame) == nil)
    let clipped = ([display] + keys).map { q in
        func p(_ p: ImagePoint) -> ImagePoint { ImagePoint(x: p.x - 0.22, y: p.y) }
        return PanelQuad(topLeft: p(q.topLeft), topRight: p(q.topRight),
                         bottomRight: p(q.bottomRight), bottomLeft: p(q.bottomLeft))
    }
    #expect(detector.wideControlStrip(keys: clipped, frame: frame) == nil)
}

// Vision key bounds captured at 720x1280. wideControlStrip uses these axis-aligned
// extents internally; retain every detection, including background and nested boxes.

// microwave-15.jpg, plain.
private let glarePlainKeyBounds: [PanelQuad] = [
    imageRect(0.339830309153, 0.067968070507, 0.349165290594, 0.129092335701),
    imageRect(0.877893030643, 0.745084583759, 0.099165201187, 0.118375703692),
    imageRect(0.327639490366, 0.700258225203, 0.088053941727, 0.054880112410),
    imageRect(0.565066695213, 0.666291415691, 0.077408730984, 0.052263528109),
    imageRect(0.598261952400, 0.322837114334, 0.088816165924, 0.031409859657),
    imageRect(0.341201573610, 0.394566059113, 0.059826195240, 0.026903092861),
    imageRect(0.336923271418, 0.604852437973, 0.080483168364, 0.035821527243),
    imageRect(0.470615208149, 0.385655164719, 0.079614341259, 0.034891724586),
    imageRect(0.084222093225, 0.230036437511, 0.066056162119, 0.051948010921),
    imageRect(0.308969199657, 0.273916542530, 0.119549751282, 0.017250895500),
    imageRect(0.470218420029, 0.271258533001, 0.087946891785, 0.018869996071),
    imageRect(0.337925612926, 0.336259841919, 0.068670392036, 0.020866155624),
    imageRect(0.614475905895, 0.272806286812, 0.064754664898, 0.017037808895),
    imageRect(0.614562511444, 0.214640736580, 0.034480571747, 0.040165126324),
    imageRect(0.030446769670, 0.029248654842, 0.047753943130, 0.025255858898),
    imageRect(0.889582812786, 0.360146343708, 0.033469080925, 0.034936249256),
    imageRect(0.012336065061, 0.256147384644, 0.065670046024, 0.018526852131),
    imageRect(0.470372557640, 0.726778566837, 0.048539817333, 0.025798469782),
    imageRect(0.486850142479, 0.551923364401, 0.030355751514, 0.025586664677),
    imageRect(0.491283982992, 0.469689130783, 0.030621975660, 0.026593804359),
    imageRect(0.773692846298, 0.942115686834, 0.034366846085, 0.020906519145),
    imageRect(0.210242137313, 0.175099670887, 0.028024569154, 0.029177725315),
    imageRect(0.609859764576, 0.501851141453, 0.028105080128, 0.022146612406),
    imageRect(0.853447854519, 0.096021234989, 0.031284213066, 0.021477282047),
]

// microwave-15.jpg, q85.
private let glareQ85KeyBounds: [PanelQuad] = [
    imageRect(0.339908719063, 0.067996382713, 0.348145365715, 0.128868401051),
    imageRect(0.874611616135, 0.745084583759, 0.102935850620, 0.130607217550),
    imageRect(0.333053559065, 0.701395720243, 0.081180006266, 0.052863046527),
    imageRect(0.565561830997, 0.666329205036, 0.077212452888, 0.052139222622),
    imageRect(0.447256445885, 0.010572969913, 0.052288502455, 0.055091321468),
    imageRect(0.598261952400, 0.322837114334, 0.088816165924, 0.031409859657),
    imageRect(0.334832012653, 0.604816704988, 0.082256644964, 0.035248249769),
    imageRect(0.341408759356, 0.394789397717, 0.059619009495, 0.026662647724),
    imageRect(0.470615208149, 0.385655164719, 0.079614341259, 0.034891724586),
    imageRect(0.308896452188, 0.273347258568, 0.116359889507, 0.017914474010),
    imageRect(0.289329379797, 0.934379920363, 0.079441249371, 0.033291637897),
    imageRect(0.935104012489, 0.141296923161, 0.049657642841, 0.047143578529),
    imageRect(0.380974560976, 0.764821350574, 0.048868060112, 0.033918112516),
    imageRect(0.337925612926, 0.336259841919, 0.068650275469, 0.020866155624),
    imageRect(0.659490108490, 0.653726726770, 0.029884517193, 0.041113913059),
    imageRect(0.510921120644, 0.626190960407, 0.058605670929, 0.028156578541),
    imageRect(0.614475905895, 0.272806286812, 0.064754664898, 0.017037808895),
    imageRect(0.072834432125, 0.202308118343, 0.055989623070, 0.021597862244),
    imageRect(0.488783746958, 0.510535895824, 0.034009724855, 0.027119934559),
    imageRect(0.486850142479, 0.551923364401, 0.030355751514, 0.025586664677),
    imageRect(0.491283982992, 0.469689130783, 0.030621975660, 0.026593804359),
    imageRect(0.609859764576, 0.501851141453, 0.028105080128, 0.022146612406),
    imageRect(0.493022084236, 0.427546501160, 0.039831697941, 0.014533877373),
    imageRect(0.864481925964, 0.491958737373, 0.019802808762, 0.015783101320),
]

// microwave-11.jpg, plain.
private let columnPlainKeyBounds: [PanelQuad] = [
    imageRect(0.209445685148, 0.270139813423, 0.314757019281, 0.098741710186),
    imageRect(0.183587551117, 0.386739611626, 0.187982499599, 0.064181745052),
    imageRect(0.200124680996, 0.395846307278, 0.134065628052, 0.044839501381),
    imageRect(0.240602895617, 0.491561770439, 0.126323118806, 0.041390299797),
    imageRect(0.474803984165, 0.372487485409, 0.098076164722, 0.043723165989),
    imageRect(0.259574711323, 0.535575896502, 0.122367560863, 0.039142429829),
    imageRect(0.365043938160, 0.433368086815, 0.103679716587, 0.042282223701),
    imageRect(0.486222475767, 0.422588407993, 0.099338740110, 0.040859341621),
    imageRect(0.555604398251, 0.592256724834, 0.064560174942, 0.036852955818),
    imageRect(0.279667913914, 0.576706260443, 0.114011049271, 0.037390649319),
    imageRect(0.294308722019, 0.616253256798, 0.110608875751, 0.035117238760),
    imageRect(0.326438546181, 0.688632220030, 0.105839312077, 0.033319026232),
    imageRect(0.452281445265, 0.282066345215, 0.051118642092, 0.049158513546),
    imageRect(0.388375014067, 0.086687028408, 0.065089404583, 0.040846168995),
    imageRect(0.876313507557, 0.485354483128, 0.051604390144, 0.063989609480),
    imageRect(0.839628458023, 0.058270215988, 0.089602589607, 0.030332326889),
    imageRect(0.420709520578, 0.609812885523, 0.053786605597, 0.028760135174),
    imageRect(0.727573037148, 0.280934154987, 0.061553657055, 0.027552962303),
    imageRect(0.478717654943, 0.084163546562, 0.041807800531, 0.022298276424),
    imageRect(0.534487903118, 0.487383127213, 0.030813276768, 0.021179914474),
    imageRect(0.468650817871, 0.494619786739, 0.028132915497, 0.019582033157),
    imageRect(0.691205501556, 0.544672429562, 0.018025457859, 0.021092116833),
    imageRect(0.779493808746, 0.268088638783, 0.032348573208, 0.015899360180),
]

// microwave-11.jpg, q85.
private let columnQ85KeyBounds: [PanelQuad] = [
    imageRect(0.210953399539, 0.270189344883, 0.314653888345, 0.098936140537),
    imageRect(0.352948069572, 0.364887118340, 0.250050604343, 0.129939377308),
    imageRect(0.059880524874, 0.590312808752, 0.118056386709, 0.070202529430),
    imageRect(0.302339792252, 0.676703423262, 0.141931414604, 0.052764952183),
    imageRect(0.200127810240, 0.395764052868, 0.134402394295, 0.044923245907),
    imageRect(0.236960098147, 0.491561770439, 0.130067631602, 0.041267693043),
    imageRect(0.474803984165, 0.372427463531, 0.097846448421, 0.043783187866),
    imageRect(0.263196229935, 0.536019712687, 0.119062244892, 0.039060533047),
    imageRect(0.365043938160, 0.433333575726, 0.103166520596, 0.042248845100),
    imageRect(0.486222475767, 0.422574222088, 0.099739581347, 0.040982365608),
    imageRect(0.555604398251, 0.592256724834, 0.064560174942, 0.036852955818),
    imageRect(0.279667913914, 0.576706260443, 0.113797128201, 0.037701904774),
    imageRect(0.294233560562, 0.615598708391, 0.110553801060, 0.035642683506),
    imageRect(0.830510795116, 0.820692643523, 0.095066905022, 0.048001632094),
    imageRect(0.326421797276, 0.688632220030, 0.105856060982, 0.033409953117),
    imageRect(0.452281445265, 0.282066345215, 0.051118642092, 0.049158513546),
    imageRect(0.805965662003, 0.635923087597, 0.079276621342, 0.036434143782),
    imageRect(0.388569414616, 0.084472954273, 0.064049899578, 0.043024361134),
    imageRect(0.427453190088, 0.613649964333, 0.040533602238, 0.021105170250),
    imageRect(0.870458126068, 0.010027825832, 0.066804349422, 0.030312836170),
    imageRect(0.070240512490, 0.752308934927, 0.043831035495, 0.016850739717),
    imageRect(0.468650817871, 0.494619786739, 0.028132915497, 0.019582033157),
    imageRect(0.097365014255, 0.795048192143, 0.023311093450, 0.011889070272),
]

// oven1_neat.jpg, camera TIFF.
private let ovenCameraKeyBounds: [PanelQuad] = [
    imageRect(0.280219584703, 0.285388469696, 0.422598630190, 0.132726669312),
    imageRect(0.327549785376, 0.713986039162, 0.347423762083, 0.062173157930),
    imageRect(0.766918361187, 0.306395947933, 0.162331223488, 0.078254640102),
    imageRect(0.445379823446, 0.454017937183, 0.100722402334, 0.082962721586),
    imageRect(0.349013209343, 0.605940103531, 0.119168996811, 0.024964183569),
    imageRect(0.315149277449, 0.861747562885, 0.067694038153, 0.046774908900),
    imageRect(0.084001764655, 0.379425764084, 0.074786469340, 0.046562016010),
    imageRect(0.672226428986, 0.476606667042, 0.077882468700, 0.036509364843),
    imageRect(0.577947735786, 0.478002905846, 0.053550124168, 0.034081429243),
    imageRect(0.347997486591, 0.476827323437, 0.073837190866, 0.040290683508),
    imageRect(0.819009125233, 0.326806783676, 0.085595548153, 0.042013227940),
    imageRect(0.523173332214, 0.607040882111, 0.097629487514, 0.023601680994),
    imageRect(0.114391356707, 0.458129346371, 0.070867940784, 0.045988589525),
    imageRect(0.482196450233, 0.922585621476, 0.106471598148, 0.025256030262),
    imageRect(0.088141180575, 0.427849352360, 0.075435347855, 0.018731117249),
    imageRect(0.471357792616, 0.480769097805, 0.054604023695, 0.030426114798),
    imageRect(0.457230687141, 0.439981758595, 0.075092673302, 0.019177913666),
    imageRect(0.171879604459, 0.276017248631, 0.072725042701, 0.026568889618),
    imageRect(0.156098246574, 0.444519817829, 0.067382812500, 0.028102517128),
    imageRect(0.739820897579, 0.577465742826, 0.062921285629, 0.020978629589),
    imageRect(0.091890081763, 0.385267913342, 0.050920501351, 0.024421215057),
    imageRect(0.241962328553, 0.085652410984, 0.047959223390, 0.016190886497),
    imageRect(0.680632829666, 0.920522399247, 0.041163742542, 0.017906062305),
    imageRect(0.013970283791, 0.716331124306, 0.044704960659, 0.011130332947),
    imageRect(0.014796345495, 0.882441423833, 0.020949208178, 0.010295040905),
]

// B19FC733-A102-4B3A-9656-37CAAA092FC9.jpg, camera TIFF.
private let washerCameraKeyBounds: [PanelQuad] = [
    imageRect(0.013232280500, 0.661992251873, 0.921180377714, 0.290179789066),
    imageRect(0.106091253459, 0.706688016653, 0.528503783047, 0.253785640001),
    imageRect(0.799100637436, 0.308492302895, 0.154402136803, 0.152900218964),
    imageRect(0.821308016777, 0.353206396103, 0.155473172665, 0.070361435413),
    imageRect(0.214724078774, 0.388727307320, 0.184882774949, 0.050508677959),
    imageRect(0.320079833269, 0.469946205616, 0.094696849585, 0.087224632502),
    imageRect(0.564735651016, 0.330029249191, 0.109298825264, 0.062500894070),
    imageRect(0.898903906345, 0.301753997803, 0.082928478718, 0.044129312038),
    imageRect(0.891334354877, 0.156832277775, 0.091964244843, 0.046007752419),
    imageRect(0.674224138260, 0.373872101307, 0.085262358189, 0.055983543396),
    imageRect(0.436916977167, 0.517693608999, 0.069162994623, 0.024710983038),
    imageRect(0.826845109463, 0.620647758245, 0.076407432556, 0.026660859585),
    imageRect(0.272779047489, 0.444917619228, 0.049749821424, 0.028409540653),
    imageRect(0.370998591185, 0.090609073639, 0.063174009323, 0.028706014156),
    imageRect(0.624727368355, 0.484286189079, 0.051310122013, 0.038530707359),
    imageRect(0.226183444262, 0.489202141762, 0.070165097713, 0.020879715681),
    imageRect(0.015646731481, 0.398575723171, 0.061582962051, 0.017089545727),
    imageRect(0.126623392105, 0.552042931318, 0.069525733590, 0.019223690033),
    imageRect(0.335585653782, 0.480026602745, 0.060844212770, 0.019200384617),
    imageRect(0.919246733189, 0.845833450556, 0.042984664440, 0.036360740662),
    imageRect(0.406815022230, 0.438143253326, 0.038601040840, 0.022617995739),
    imageRect(0.764901399612, 0.336286365986, 0.030719280243, 0.038629233837),
    imageRect(0.633292257786, 0.470068395138, 0.030825495720, 0.017568409443),
    imageRect(0.794019103050, 0.162106990814, 0.027557373047, 0.021148920059),
    imageRect(0.022591704503, 0.422848820686, 0.021309042349, 0.010830104351),
]

@Test("Real JPEG microwave columns cannot become short control strips", arguments: [0, 1, 2, 3])
func jpegControlStripRegression(index: Int) {
    let keys = [glarePlainKeyBounds, glareQ85KeyBounds, columnPlainKeyBounds, columnQ85KeyBounds][index]
    let detector = PanelDetector()
    let frame = PixelSize(width: 720, height: 1280)
    #expect(detector.wideControlStrip(keys: keys, frame: frame) == nil)
    #expect(detector.wideControlStrip(keys: keys.reversed(), frame: frame) == nil)
}

@Test("Real oven background boxes and compact washer controls remain usable")
func realControlStripPreservation() throws {
    let detector = PanelDetector()
    let frame = PixelSize(width: 720, height: 1280)
    let ovenCamera = try #require(detector.wideControlStrip(keys: ovenCameraKeyBounds, frame: frame))
    #expect(abs(ovenCamera.topLeft.x - 0.069001764655) < 1e-8)
    #expect(abs(ovenCamera.topLeft.y - 0.261017248631) < 1e-8)
    #expect(abs(ovenCamera.bottomRight.x - 0.944249584675) < 1e-8)
    #expect(abs(ovenCamera.bottomRight.y - 0.551980658770) < 1e-8)
    let washerCamera = try #require(detector.wideControlStrip(keys: washerCameraKeyBounds, frame: frame))
    #expect(abs(washerCamera.topLeft.x - 0.111623392105) < 1e-8)
    #expect(abs(washerCamera.topLeft.y - 0.373727307320) < 1e-8)
    #expect(abs(washerCamera.bottomRight.x - 0.521079971790) < 1e-8)
    #expect(abs(washerCamera.bottomRight.y - 0.586266621351) < 1e-8)
}
