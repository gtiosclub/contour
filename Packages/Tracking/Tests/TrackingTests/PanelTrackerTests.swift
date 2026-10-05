import ContourCore
import ContourMocks
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import Tracking

@Suite("Panel tracking with recorded fixtures (real Vision)")
struct PanelTrackerFixtureTests {
    @Test("Register on the reference, then follow the panel into a moved frame")
    func followsMovedPanel() async throws {
        let fixture = try Fixture.load()
        let tracker = PanelTracker()
        try await tracker.startTracking(try reference(image: "panel-reference", quad: fixture.reference))

        let observation = try await tracker.track(try frame(image: "panel-moved", at: 10))
        #expect(observation.status == .tracked)
        #expect(observation.timestamp == Date(timeIntervalSince1970: 10))
        let quad = try #require(observation.quad)
        #expect(maxCornerError(quad, fixture.moved) <= fixture.tolerance,
                "corners off by \(maxCornerError(quad, fixture.moved))")
    }

    @Test("A blank frame reports loss with no corners")
    func blankFrameIsLost() async throws {
        let fixture = try Fixture.load()
        let tracker = PanelTracker()
        try await tracker.startTracking(try reference(image: "panel-reference", quad: fixture.reference))

        let observation = try await tracker.track(try blankFrame(at: 11))
        #expect(observation.status != .tracked)
        #expect(observation.quad == nil)
        #expect(observation.confidence == 0)
    }

    @Test("Restart with a replacement reference after loss")
    func restartsAfterLoss() async throws {
        let fixture = try Fixture.load()
        let tracker = PanelTracker()
        try await tracker.startTracking(try reference(image: "panel-reference", quad: fixture.reference))
        _ = try await tracker.track(try blankFrame(at: 1))

        try await tracker.startTracking(try reference(image: "panel-moved", quad: fixture.moved))
        let observation = try await tracker.track(try frame(image: "panel-moved", at: 2))
        #expect(observation.status == .tracked)
        #expect(maxCornerError(try #require(observation.quad), fixture.moved) <= fixture.tolerance)
    }

    @Test("Camera frames a different size from the reference still track")
    func tracksFramesOfAnotherSize() async throws {
        let fixture = try Fixture.load()
        let tracker = PanelTracker()
        try await tracker.startTracking(try reference(image: "panel-reference", quad: fixture.reference))

        // The reference is 640x480; the same view at 1280x960, like a camera
        // whose resolution doesn't match the photo the panel was found in. A
        // sequence that had seen the 640x480 still lost the panel here.
        let observation = try await tracker.track(try frame(image: "panel-reference", at: 3, scale: 2))
        #expect(observation.status == .tracked)
        #expect(maxCornerError(try #require(observation.quad), fixture.reference) <= fixture.tolerance)
    }

    @Test("Losing the panel for a frame doesn't end tracking: it comes back on its own")
    func recoversAfterLoss() async throws {
        let fixture = try Fixture.load()
        let tracker = PanelTracker()
        try await tracker.startTracking(try reference(image: "panel-reference", quad: fixture.reference))

        #expect(try await tracker.track(try blankFrame(at: 1)).status != .tracked)
        let observation = try await tracker.track(try frame(image: "panel-moved", at: 2))
        #expect(observation.status == .tracked)
        #expect(maxCornerError(try #require(observation.quad), fixture.moved) <= fixture.tolerance)
    }
}

@Suite("Panel tracking state and coordinates (scripted Vision)")
struct PanelTrackerTests {
    @Test("Vision y-up corners become image y-down, identities kept, capture time kept")
    func imageCoordinates() async throws {
        let tracker = PanelTracker { _ in ScriptedTracker { _ in vision(square, confidence: 0.9) } }
        try await tracker.startTracking(try scriptedReference())
        let observation = try await tracker.track(try blankFrame(at: 123))
        #expect(observation.timestamp == Date(timeIntervalSince1970: 123))
        #expect(observation.quad == square)
        #expect(observation.confidence == 0.9)
    }

    @Test("Not started and stopped both report notStarted")
    func notStarted() async throws {
        let tracker = PanelTracker { _ in ScriptedTracker { _ in vision(square) } }
        #expect(try await tracker.track(try blankFrame(at: 1)).status == .lost(.notStarted))
        try await tracker.startTracking(try scriptedReference())
        await tracker.stopTracking()
        await tracker.stopTracking() // idempotent
        #expect(try await tracker.track(try blankFrame(at: 2)).status == .lost(.notStarted))
    }

    @Test("Missing, weak, or folded results never carry old corners forward")
    func noStaleCorners() async throws {
        let bowtie = PanelQuad(topLeft: square.topLeft, topRight: square.bottomRight,
                               bottomRight: square.topRight, bottomLeft: square.bottomLeft)
        let tracker = PanelTracker { _ in
            ScriptedTracker { image in
                switch seconds(image) {
                case 2: nil
                case 3: vision(square, confidence: 0.1)
                case 4: vision(bowtie)
                default: vision(square)
                }
            }
        }
        try await tracker.startTracking(try scriptedReference())
        #expect(try await tracker.track(try blankFrame(at: 1)).status == .tracked)
        for (time, reason) in [(2.0, PanelObservation.LossReason.notFound),
                               (3, .lowConfidence), (4, .invalidGeometry)] {
            let lost = try await tracker.track(try blankFrame(at: time))
            #expect(lost.status == .lost(reason))
            #expect(lost.quad == nil)
        }
        #expect(try await tracker.track(try blankFrame(at: 5)).quad == square)
    }

    @Test("After a Vision error, the next frame starts again from the last good position")
    func recoversFromTrackerFailure() async throws {
        let starts = Recorder<PanelQuad>()
        let tracker = PanelTracker { start in
            starts.append(start)
            return ScriptedTracker { image in
                if seconds(image) == 1 { throw ScriptedFailure.failed }
                return vision(square)
            }
        }
        try await tracker.startTracking(try scriptedReference())
        #expect(try await tracker.track(try blankFrame(at: 1)).status == .lost(.trackerFailed))

        let next = try await tracker.track(try blankFrame(at: 2))
        #expect(next.status == .tracked)
        #expect(next.quad == square)
        // Registration, the live sequence, and a fresh one after the error,
        // seeded from the last good quad.
        #expect(starts.values == [square, square, square])
    }

    @Test("Camera frames get their own sequence, shown the reference at the frame's size first")
    func referenceUsesAThrowawaySequence() async throws {
        let seen = Recorder<String>()
        let made = Recorder<Int>()
        let tracker = PanelTracker { _ in
            let index = made.values.count
            made.append(index)
            return ScriptedTracker { image in
                switch image {
                case let .still(still, _): seen.append("\(index):still \(still.width)x\(still.height)")
                case let .frame(frame): seen.append("\(index):frame \(CVPixelBufferGetWidth(frame.pixelBuffer))")
                }
                return vision(square)
            }
        }
        try await tracker.startTracking(try scriptedReference())
        let large = { (at: TimeInterval) in try frame(width: 1280, height: 960, at: at) { _ in } }
        _ = try await tracker.track(try large(1))
        _ = try await tracker.track(try large(2))

        #expect(seen.values == ["0:still 640x480", "1:still 1280x960", "1:frame 1280", "1:frame 1280"])
    }

    @Test("Corner identities survive the phone rolling past 45°")
    func cornerIdentity() {
        // Vision relabels by screen position: its "top left" is now our top right.
        let relabelled = PanelQuad(topLeft: square.bottomLeft, topRight: square.topLeft,
                                   bottomRight: square.topRight, bottomLeft: square.bottomRight)
        #expect(PanelTracker.aligned(relabelled, to: square) == square)
        #expect(PanelTracker.aligned(square, to: square) == square)
    }

    @Test("Bad references are rejected before Vision runs")
    func badReferences() async throws {
        let tracker = PanelTracker { _ in ScriptedTracker { _ in vision(square) } }
        let line = PanelQuad(topLeft: ImagePoint(x: 0, y: 0), topRight: ImagePoint(x: 0.5, y: 0),
                             bottomRight: ImagePoint(x: 1, y: 0), bottomLeft: ImagePoint(x: 0.2, y: 0))
        await #expect(throws: PanelTrackingError.invalidReferenceQuad) {
            try await tracker.startTracking(try scriptedReference(quad: line))
        }
        await #expect(throws: PanelTrackingError.unreadableReferencePhoto) {
            try await tracker.startTracking(try scriptedReference(data: Data([1, 2, 3])))
        }
    }

    @Test("Registration fails if Vision can't hold the panel in the reference itself")
    func registrationFailure() async throws {
        let tracker = PanelTracker { _ in ScriptedTracker { _ in nil } }
        await #expect(throws: PanelTrackingError.registrationFailed) {
            try await tracker.startTracking(try scriptedReference())
        }
        #expect(try await tracker.track(try blankFrame(at: 1)).status == .lost(.notStarted))
    }

    @Test("A result that finishes after stop or restart is discarded, not published")
    func supersededUpdate() async throws {
        let gate = Gate()
        let tracker = PanelTracker { _ in
            ScriptedTracker { image in
                if seconds(image) == 1 { await gate.wait() }
                return vision(square)
            }
        }
        try await tracker.startTracking(try scriptedReference())
        let pending = Task { try await tracker.track(try blankFrame(at: 1)) }
        await gate.waitUntilBlocked()

        // Frames are a chain: a second one can't start while the first is out.
        await #expect(throws: PanelTrackingError.frameInFlight) {
            try await tracker.track(try blankFrame(at: 2))
        }
        await tracker.stopTracking()
        await gate.open()
        await #expect(throws: PanelTrackingError.superseded) { try await pending.value }
    }

    @Test("currentPose asserts nothing until metric pose exists")
    func poseIsUnknown() async {
        #expect(await PanelTracker().currentPose() == .unknown)
    }
}

// MARK: - Scripted Vision

private let square = PanelQuad(
    topLeft: ImagePoint(x: 0.25, y: 0.25), topRight: ImagePoint(x: 0.75, y: 0.25),
    bottomRight: ImagePoint(x: 0.75, y: 0.75), bottomLeft: ImagePoint(x: 0.25, y: 0.75))

private enum ScriptedFailure: Error { case failed }

/// Upright image quad → what Vision would report (y up).
private func vision(_ quad: PanelQuad, confidence: Double = 1) -> VisionQuad {
    func up(_ p: ImagePoint) -> SIMD2<Double> { SIMD2(p.x, 1 - p.y) }
    return VisionQuad(topLeft: up(quad.topLeft), topRight: up(quad.topRight),
                      bottomRight: up(quad.bottomRight), bottomLeft: up(quad.bottomLeft),
                      confidence: confidence)
}

/// Camera frames carry their script step in the timestamp; the still is step 0.
private func seconds(_ image: TrackerImage) -> TimeInterval {
    if case let .frame(frame) = image { frame.timestamp.timeIntervalSince1970 } else { 0 }
}

private final class ScriptedTracker: RectangleTracking {
    private let script: @Sendable (TrackerImage) async throws -> VisionQuad?
    init(_ script: @escaping @Sendable (TrackerImage) async throws -> VisionQuad?) {
        self.script = script
    }
    nonisolated(nonsending) func update(_ image: TrackerImage) async throws -> VisionQuad? {
        try await script(image)
    }
}

/// Holds one caller until opened, so a test can act while Vision is "busy".
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiter = $0; blocked?.resume(); blocked = nil }
    }
    func waitUntilBlocked() async {
        if waiter != nil { return }
        await withCheckedContinuation { blocked = $0 }
    }
    func open() { waiter?.resume(); waiter = nil }
}

// MARK: - Fixtures

private struct Fixture: Decodable {
    let tolerance: Double
    let reference: PanelQuad
    let moved: PanelQuad

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "panel-corners", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corners = try JSONDecoder().decode(Corners.self, from: Data(contentsOf: url))
        return Fixture(tolerance: corners.tolerance,
                       reference: corners.reference.quad, moved: corners.moved.quad)
    }

    private struct Corners: Decodable {
        let tolerance: Double
        let reference: [ImagePoint]
        let moved: [ImagePoint]
    }
}

private extension Array where Element == ImagePoint {
    var quad: PanelQuad { PanelQuad(topLeft: self[0], topRight: self[1], bottomRight: self[2], bottomLeft: self[3]) }
}

private func maxCornerError(_ a: PanelQuad, _ b: PanelQuad) -> Double {
    TrackingQualityEvaluator.cornerShift(a, b)
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func reference(image name: String, quad: PanelQuad) throws -> PanelReference {
    try reference(data: fixtureData(name), quad: quad)
}

private func scriptedReference(quad: PanelQuad = square, data: Data? = nil) throws -> PanelReference {
    // Any decodable image will do; the scripted tracker ignores the pixels.
    try reference(data: data ?? fixtureData("panel-reference"), quad: quad)
}

private func reference(data: Data, quad: PanelQuad) throws -> PanelReference {
    let photo = PanelPhoto(data: data, pixelSize: PixelSize(width: 640, height: 480),
                           timestamp: Date(timeIntervalSince1970: 0))
    return try PanelReference(photo: photo, detection: PanelDetection(
        referencePhotoID: photo.id, quad: quad, map: MockSurfaceMaps.microwave))
}

private func frame(image name: String, at seconds: TimeInterval, scale: Int = 1) throws -> CameraFrame {
    let source = try #require(CGImageSourceCreateWithData(try fixtureData(name) as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width * scale, height = image.height * scale
    return try frame(width: width, height: height, at: seconds) { context in
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// Collects values from the scripted tracker's closures, which run off the test.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}

private func blankFrame(at seconds: TimeInterval) throws -> CameraFrame {
    try frame(width: 640, height: 480, at: seconds) { context in
        context.setFillColor(gray: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
    }
}

private func frame(width: Int, height: Int, at seconds: TimeInterval,
                   draw: (CGContext) -> Void) throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_32BGRA, nil, &buffer)
    #expect(status == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let context = try #require(CGContext(
        data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    draw(context)
    return CameraFrame(pixelBuffer: pixels, timestamp: Date(timeIntervalSince1970: seconds))
}
