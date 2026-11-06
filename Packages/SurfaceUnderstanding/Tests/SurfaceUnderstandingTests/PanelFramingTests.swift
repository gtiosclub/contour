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
    #expect(PanelFraming().advice(for: .fullFrame, frame: framingSize) == .noPanel)
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
    #expect(await PanelFraming().advice(for: fullFrame) == .noPanel)
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

// Full maps captured on main d7ebc33 with LiveSurfaceUnderstanding, upright
// 720x1280 JPEGs. Keep the background detections: removing them would hide the
// ambiguity that the full-frame rule must handle. No Vision runs in these tests.
private func framingButtons(_ values: [[Double]]) -> [PanelRect] {
    values.map { PanelRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
}

// drive/glare_microwave.jpg
private let framingCloseButtons = framingButtons([
    [0.050603647, 0.028036773, 0.403518718, 0.086678505],
    [0.013405125, 0.727362067, 0.206209523, 0.070983127],
    [0.024419980, 0.658261389, 0.166703356, 0.059657902],
    [0.200059429, 0.578679889, 0.159173056, 0.059979290],
    [0.204177365, 0.653342515, 0.157029286, 0.058529168],
    [0.197090819, 0.510937601, 0.160346791, 0.056564361],
    [0.381102026, 0.648342878, 0.149535298, 0.057355970],
    [0.376757890, 0.504975021, 0.143566161, 0.058975935],
    [0.184189186, 0.272096813, 0.164279386, 0.052298784],
    [0.374748528, 0.572484821, 0.134821415, 0.062898695],
    [0.194043934, 0.412537456, 0.159110308, 0.050117195],
    [0.377807349, 0.344636977, 0.155128568, 0.048483014],
    [0.188116208, 0.342779815, 0.145604536, 0.050143123],
    [0.219614647, 0.733061612, 0.136333145, 0.049799979],
    [0.382101893, 0.271390319, 0.146630406, 0.023114920],
    [0.015492143, 0.284384429, 0.121299041, 0.023759186],
    [0.015468027, 0.414403141, 0.132059012, 0.020826638],
    [0.911420405, 0.672351450, 0.079872847, 0.040271968],
    [0.013297493, 0.199958682, 0.106827220, 0.021886349],
    [0.411751747, 0.439589322, 0.099502921, 0.020244360],
    [0.383299947, 0.409323394, 0.028451800, 0.053711891],
    [0.807798743, 0.788732484, 0.055099905, 0.035708785],
    [0.176836942, 0.195691496, 0.176881668, 0.056912855],
    [0.388619793, 0.198515625, 0.136649305, 0.056093750],
    [0.013385416, 0.221718750, 0.112118056, 0.028437500],
    [0.396718751, 0.298281250, 0.120451389, 0.028437500],
    [-0.005007822, 0.354466278, 0.170746438, 0.032139260],
    [0.397421876, 0.411484375, 0.124600694, 0.022343750],
    [-0.003281250, 0.437343750, 0.178784722, 0.028437500],
    [0.149730904, 0.481328125, 0.236649300, 0.026406250],
    [0.076571181, 0.522578126, 0.041302083, 0.034531249],
    [0.079114583, 0.592656250, 0.052881944, 0.036562500],
    [0.413619792, 0.723515625, 0.097760417, 0.026406250],
    [0.405989584, 0.753906250, 0.110243056, 0.020312500]
])

// vrishin/2026-10-22T21_08_29.025Z-0002.jpg
private let framingFarButtons = framingButtons([
    [0.400777221, 0.665651023, 0.212691069, 0.058232814],
    [0.844031334, 0.364491284, 0.063320756, 0.038719714],
    [0.840775073, 0.329310000, 0.044941664, 0.030237079],
    [0.034609888, 0.863571346, 0.059270505, 0.029544950],
    [0.164231032, 0.226694167, 0.042780817, 0.021056712],
    [0.709451675, 0.470011592, 0.033062637, 0.029579699],
    [0.215952605, 0.557552397, 0.042222738, 0.023256004],
    [0.575017393, 0.966830093, 0.047793984, 0.020917727],
    [0.719749629, 0.204241812, 0.021546781, 0.010795712],
    [0.596050347, 0.280078125, 0.027343750, 0.010156250],
    [0.529356957, 0.350363900, 0.055174977, 0.019673781],
    [0.395524095, 0.355911226, 0.064507364, 0.013177548],
    [0.532161458, 0.380078125, 0.049565973, 0.017968750],
    [0.398497792, 0.381365392, 0.075226640, 0.021780408],
    [0.523828126, 0.412890625, 0.069010417, 0.010156250],
    [0.415494791, 0.414453125, 0.041232639, 0.010156250],
    [0.531927084, 0.437656250, 0.055590278, 0.020000000],
    [0.412379294, 0.440424141, 0.055796966, 0.018696731],
    [0.459939236, 0.469140625, 0.077343747, 0.010156250],
    [0.492803820, 0.481171875, 0.017170139, 0.014218750],
    [0.562248264, 0.513984375, 0.019947916, 0.014218750],
    [0.565260417, 0.543906250, 0.016701389, 0.012187500],
    [0.423359375, 0.545234375, 0.017170138, 0.014218750],
    [0.495815972, 0.545468750, 0.016701389, 0.012187500],
    [0.554383681, 0.573828125, 0.041232639, 0.010156250],
    [0.415729167, 0.577187500, 0.040763889, 0.008125000],
    [0.482161459, 0.583203125, 0.049565972, 0.010156250],
    [0.415494794, 0.601953125, 0.044010414, 0.010156250],
    [0.557161459, 0.603515625, 0.035677083, 0.010156250],
    [0.548828126, 0.623828125, 0.052343750, 0.010156250],
    [0.418272569, 0.626953125, 0.044010417, 0.010156250]
])

// vrishin/2026-10-22T21_04_00.453Z-0011.jpg
private let framingUncertainButtons = framingButtons([
    [0.015646731, 0.448013365, 0.311902756, 0.101017863],
    [0.522316217, 0.404265463, 0.132061303, 0.031792581],
    [0.900755584, 0.410173714, 0.084439874, 0.041731536],
    [0.286713332, 0.131658792, 0.056573361, 0.040492296],
    [0.380178809, 0.140790582, 0.051392257, 0.026659071],
    [0.530552149, 0.478552699, 0.063904583, 0.026032478],
    [0.467156082, 0.905443706, 0.039926142, 0.015230685],
    [0.926324785, 0.614021659, 0.036508560, 0.020622879],
    [0.748214126, 0.127661705, 0.026268423, 0.018158495],
    [0.066217043, 0.301196516, 0.032172330, 0.015976012],
    [0.528763021, 0.524335937, 0.039696183, 0.039609375]
])

@Test("Full-frame advice uses real clipped, distant and ambiguous scan boxes")
func framingFullFrameRealButtons() {
    let framing = PanelFraming()
    #expect(framing.advice(for: .fullFrame, frame: framingSize, buttonBounds: framingCloseButtons) == .moveBack)
    #expect(framing.advice(for: .fullFrame, frame: framingSize, buttonBounds: framingFarButtons) == .moveCloser)
    #expect(framing.advice(for: .fullFrame, frame: framingSize, buttonBounds: framingUncertainButtons) == .noPanel)
    // Legacy callers and the fast photo path have no scan boxes to establish distance.
    #expect(framing.advice(for: .fullFrame, frame: framingSize) == .noPanel)
}

@Test("Full-frame evidence must be finite, distinct and more than a lone edge box")
func framingFullFrameInsufficientEvidence() {
    let framing = PanelFraming()
    let clipped = PanelRect(x: -0.003, y: 0.4, width: 0.17, height: 0.03)
    let invalid = PanelRect(x: .nan, y: 0.4, width: 0.1, height: 0.03)
    for boxes in [[clipped], Array(repeating: clipped, count: 8), framingFarButtons + [invalid]] {
        #expect(framing.advice(for: .fullFrame, frame: framingSize, buttonBounds: boxes) == .noPanel)
    }
    #expect(framing.advice(for: nil, frame: framingSize, buttonBounds: framingFarButtons) == .noPanel)
    #expect(framing.advice(for: .fullFrame, frame: PixelSize(width: 0, height: 1280),
                          buttonBounds: framingFarButtons) == .noPanel)
}

@Test("Scan boxes cannot change advice for a detected outline")
func framingOutlinedPanelsIgnoreButtons() {
    let quads = [
        framingBox(0.2, 0.1, 0.8, 0.9), framingBox(0.4, 0.4, 0.6, 0.6),
        framingBox(-0.1, 0.3, 1.05, 0.7), framingBox(0.01, 0.4, 0.3, 0.6),
        framingBox(0.4, 0.7, 0.6, 0.99), framingBox(0.05, 0.4, 0.35, 0.6),
        framingQuad([(0.41,0.12),(0.90,0.11),(0.89,0.84),(0.02,0.87)])
    ]
    for quad in quads {
        let expected = PanelFraming().advice(for: quad, frame: framingSize)
        for boxes in [framingCloseButtons, framingFarButtons, framingUncertainButtons] {
            #expect(PanelFraming().advice(for: quad, frame: framingSize, buttonBounds: boxes) == expected)
        }
    }
}
