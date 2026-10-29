import ContourCore
import ContourFeatureMatcher
import ContourMocks
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import Tracking

/// The Swift wrapper around the OpenCV backend: orientation, resolution,
/// normalized coordinates, loss and recovery, and reference replacement.
@Suite("Feature panel tracker")
struct FeaturePanelTrackerTests {
    typealias Fixture = FeatureMatcherBackendTests

    // MARK: Tracking

    @Test("Tracks a perspective view in normalized upright coordinates with the capture timestamp")
    func tracksUpright() async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference())
        let frame = Self.camera(Fixture.liveFrame())
        let observation = try await tracker.track(frame)

        #expect(observation.status == .tracked)
        #expect(observation.timestamp == frame.timestamp)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.006)
        #expect(observation.confidence > 0.6 && observation.confidence <= 0.95)

        let diagnostics = try #require(observation.featureDiagnostics)
        #expect(diagnostics.inlierCount >= 20)
        #expect(diagnostics.inlierPoints.count == diagnostics.inlierCount)
        #expect(diagnostics.inlierPoints.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        #expect(diagnostics.processingMilliseconds > 0)
        #expect(diagnostics.message == "ok")
    }

    @Test("Honors camera orientation: the panel lands where the upright image shows it",
          arguments: [CGImagePropertyOrientation.up, .right, .down, .left])
    func cameraOrientation(_ orientation: CGImagePropertyOrientation) async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference())
        let observation = try await tracker.track(Self.camera(Fixture.liveFrame(), orientation: orientation))
        #expect(observation.status == .tracked)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.006)
    }

    @Test("Honors reference photo orientation", arguments: [PhotoOrientation.right, .down, .left])
    func referenceOrientation(_ orientation: PhotoOrientation) async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference(orientation: orientation))
        let observation = try await tracker.track(Self.camera(Fixture.liveFrame()))
        #expect(observation.status == .tracked)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.006)
    }

    @Test("Camera-resolution inputs are downsampled without moving normalized corners")
    func resolution() async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference(Fixture.panel.upscaled(by: 3)))
        let frame = Self.camera(Fixture.liveFrame().upscaled(by: 3), orientation: .right)
        let observation = try await tracker.track(frame)
        #expect(observation.status == .tracked)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.008)
    }

    @Test("A covered corner and a covered target still yield all four corners")
    func coverage() async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference())
        let frame = Self.camera(Fixture.liveFrame(cover: [(100, 60, 170, 130), (290, 220, 70, 60)]))
        let observation = try await tracker.track(frame)
        #expect(observation.status == .tracked)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.008)
    }

    @Test("Loss carries evidence but no corners, then tracking recovers")
    func lossAndRecovery() async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference())

        let covered = try await tracker.track(Self.camera(Fixture.liveFrame(cover: [(100, 60, 430, 360)])))
        #expect(covered.quad == nil)
        #expect(covered.confidence == 0)
        #expect(covered.status == .lost(.notFound))
        let evidence = try #require(covered.featureDiagnostics)
        #expect(evidence.frameFeatures > 0)
        #expect(evidence.message != "ok")

        let unrelated = try await tracker.track(Self.camera(SyntheticGray.textured(width: 640, height: 480, seed: 11)))
        #expect(unrelated.quad == nil)

        let recovered = try await tracker.track(Self.camera(Fixture.liveFrame()))
        #expect(recovered.status == .tracked)
        expectQuad(recovered.quad, near: Self.liveQuad, within: 0.006)
    }

    // MARK: Lighting options (#83)

    @Test("Highlight exclusion follows the options and is reported in diagnostics")
    func highlightOptions() async throws {
        let frame = Self.camera(Fixture.liveFrame().withGlare())

        let filtering = FeaturePanelTracker()
        try await filtering.startTracking(Self.reference())
        let filtered = try #require(try await filtering.track(frame).featureDiagnostics)
        #expect(filtered.excludedHighlightFraction > 0.02)
        #expect(filtered.saturatedFraction >= filtered.excludedHighlightFraction)

        let unfiltered = FeaturePanelTracker(options: FeatureTrackingOptions(excludeHighlights: false))
        try await unfiltered.startTracking(Self.reference())
        let raw = try #require(try await unfiltered.track(frame).featureDiagnostics)
        #expect(raw.excludedHighlightFraction == 0)
        #expect(raw.saturatedFraction > 0.02)
    }

    @Test("Contrast normalization applies to the reference and frames alike")
    func contrastOption() async throws {
        let reference = try Self.reference(Fixture.panel.dimmed(range: 20))
        await #expect(throws: PanelTrackingError.registrationFailed) {
            try await FeaturePanelTracker().startTracking(reference)
        }
        let tracker = FeaturePanelTracker(options: FeatureTrackingOptions(normalizeContrast: true))
        try await tracker.startTracking(reference)
        let observation = try await tracker.track(Self.camera(Fixture.liveFrame().dimmed(range: 20)))
        #expect(observation.status == .tracked)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.006)
    }

    @Test("Saturation is reported even when a washed-out frame is lost")
    func washoutDiagnostics() async throws {
        let tracker = FeaturePanelTracker()
        try await tracker.startTracking(Self.reference())
        var washed = Fixture.liveFrame()
        washed.fill((120, 80, 400, 330), value: 255)
        let observation = try await tracker.track(Self.camera(washed))
        #expect(observation.quad == nil)
        #expect(try #require(observation.featureDiagnostics).saturatedFraction > 0.4)
    }

    // MARK: Lifecycle

    @Test("Without a reference every frame is lost as not started")
    func notStarted() async throws {
        let tracker = FeaturePanelTracker()
        let frame = Self.camera(Fixture.liveFrame())
        #expect(try await tracker.track(frame) == .lost(.notStarted, at: frame.timestamp))

        try await tracker.startTracking(Self.reference())
        await tracker.stopTracking()
        #expect(try await tracker.track(frame).status == .lost(.notStarted))
    }

    @Test("Registration failures are explicit and leave nothing registered")
    func registrationFailures() async throws {
        let tracker = FeaturePanelTracker()
        let frame = Self.camera(Fixture.liveFrame())

        try await tracker.startTracking(Self.reference())
        await #expect(throws: PanelTrackingError.invalidReferenceQuad) {
            try await tracker.startTracking(Self.reference(quad: PanelQuad(
                topLeft: ImagePoint(x: 0.1, y: 0.1), topRight: ImagePoint(x: 0.9, y: 0.9),
                bottomRight: ImagePoint(x: 0.9, y: 0.1), bottomLeft: ImagePoint(x: 0.1, y: 0.9))))
        }
        #expect(try await tracker.track(frame).status == .lost(.notStarted))

        await #expect(throws: PanelTrackingError.unreadableReferencePhoto) {
            try await tracker.startTracking(Self.reference(data: Data("not an image".utf8)))
        }
        await #expect(throws: PanelTrackingError.registrationFailed) {
            try await tracker.startTracking(Self.reference(SyntheticGray(width: 480, height: 360, value: 90)))
        }
        #expect(try await tracker.track(frame).status == .lost(.notStarted))
    }

    @Test("Stopping while a frame is being prepared discards that frame's result")
    func stopDuringProcessing() async throws {
        let interruption = Interruption()
        let tracker = FeaturePanelTracker(afterPreparation: { await interruption.run() })
        try await tracker.startTracking(Self.reference())

        await interruption.set { await tracker.stopTracking() }
        await #expect(throws: PanelTrackingError.superseded) {
            try await tracker.track(Self.camera(Fixture.liveFrame()))
        }
        #expect(try await tracker.track(Self.camera(Fixture.liveFrame())).status == .lost(.notStarted))
    }

    @Test("Replacing the reference mid-frame discards the old result; later frames use the new reference")
    func replacementDuringProcessing() async throws {
        let interruption = Interruption()
        let tracker = FeaturePanelTracker(afterPreparation: { await interruption.run() })
        try await tracker.startTracking(Self.reference())

        // The second panel is a different texture; the old panel's frame must not track against it.
        let other = SyntheticGray.textured(width: 480, height: 360, seed: 31)
        await interruption.set { try? await tracker.startTracking(Self.reference(other)) }
        await #expect(throws: PanelTrackingError.superseded) {
            try await tracker.track(Self.camera(Fixture.liveFrame()))
        }

        #expect(try await tracker.track(Self.camera(Fixture.liveFrame())).quad == nil)
        var otherFrame = SyntheticGray.textured(width: 640, height: 480, seed: 99)
        otherFrame.warp(other, from: Fixture.panelCorners, to: Fixture.liveCorners)
        let observation = try await tracker.track(Self.camera(otherFrame))
        #expect(observation.status == .tracked)
        expectQuad(observation.quad, near: Self.liveQuad, within: 0.006)
    }

    @Test("A registration superseded mid-preparation registers nothing")
    func registrationSuperseded() async throws {
        let interruption = Interruption()
        let tracker = FeaturePanelTracker(afterPreparation: { await interruption.run() })
        await interruption.set { await tracker.stopTracking() }
        await #expect(throws: PanelTrackingError.superseded) {
            try await tracker.startTracking(Self.reference())
        }
        #expect(try await tracker.track(Self.camera(Fixture.liveFrame())).status == .lost(.notStarted))
    }

    @Test("Cancelling a start during preparation registers nothing")
    func cancelledRegistration() async throws {
        let interruption = Interruption()
        let tracker = FeaturePanelTracker(afterPreparation: { await interruption.run() })
        try await tracker.startTracking(Self.reference())

        // The replacement is cancelled while its image is prepared; nothing
        // else starts or stops, so only cancellation can stop it.
        await interruption.set { withUnsafeCurrentTask { $0?.cancel() } }
        let start = Task { try await tracker.startTracking(Self.reference()) }
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(try await tracker.track(Self.camera(Fixture.liveFrame())).status == .lost(.notStarted))
    }

    @Test("Cancelling a frame during preparation discards its result")
    func cancelledFrame() async throws {
        let interruption = Interruption()
        let tracker = FeaturePanelTracker(afterPreparation: { await interruption.run() })
        try await tracker.startTracking(Self.reference())

        await interruption.set { withUnsafeCurrentTask { $0?.cancel() } }
        let frame = Self.camera(Fixture.liveFrame())
        let track = Task { try await tracker.track(frame) }
        await #expect(throws: CancellationError.self) { try await track.value }
        #expect(try await tracker.track(frame).status == .tracked)
    }

    // MARK: Pipeline

    @Test("Injected into LiveTrackingSource with a plain 2D camera, without AR")
    func liveTrackingSource() async throws {
        let images = [Fixture.liveFrame(), Fixture.liveFrame(cover: [(100, 60, 430, 360)]), Fixture.liveFrame()]
        let camera = FixedCamera(buffers: images.map { $0.pixelBuffer(storedFor: .right) }, orientation: .right)
        let samples = Samples()
        // Staleness is measured against the wall clock; a cold first frame on a
        // slow runner mustn't turn a tracking check into a timing check.
        var thresholds = TrackingQualityThresholds()
        thresholds.staleDegraded = 60
        thresholds.staleLost = 60
        let source = LiveTrackingSource(camera: camera, panelTracker: FeaturePanelTracker(),
                                        evaluator: TrackingQualityEvaluator(thresholds: thresholds),
                                        onSample: { samples.append($0) })
        await source.use(try Self.reference())
        #expect(await source.registrationError() == nil)
        for await _ in source.frames() {}

        let emitted = samples.all
        #expect(emitted.count == 3)
        guard emitted.count == 3 else { return }
        #expect(emitted.map(\.cameraFrame.timestamp) == camera.delivered.map(\.timestamp))
        #expect(emitted.allSatisfy { $0.featureDiagnostics != nil })
        #expect(emitted.map(\.panelStatus) == [.tracked, .lost(.notFound), .tracked])
        expectQuad(emitted[0].panelQuad, near: Self.liveQuad, within: 0.006)
        #expect(emitted[1].panelQuad == nil)
        #expect(emitted[1].panelStatus == .lost(.notFound))
        expectQuad(emitted[2].panelQuad, near: Self.liveQuad, within: 0.006)
    }

    // MARK: Calibration

    @Test("Calibration calls are forwarded and safe without a reference")
    func calibrationForwarding() async throws {
        let tracker = FeaturePanelTracker()
        await tracker.observeCalibrationView()
        #expect(await tracker.finishCalibration() == nil)
        await tracker.resetCalibration()

        try await tracker.startTracking(Self.reference())
        _ = try await tracker.track(Self.camera(Fixture.liveFrame()))
        await tracker.observeCalibrationView()
        await tracker.resetCalibration()
        #expect(try await tracker.track(Self.camera(Fixture.liveFrame())).status == .tracked)
    }

    // MARK: - Fixtures

    static func normalized(_ point: CFTPoint, width: Int, height: Int) -> ImagePoint {
        ImagePoint(x: (Double(point.x) + 0.5) / Double(width), y: (Double(point.y) + 0.5) / Double(height))
    }

    static func quad(_ corners: [CFTPoint], width: Int, height: Int) -> PanelQuad {
        let c = corners.map { normalized($0, width: width, height: height) }
        return PanelQuad(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3])
    }

    static let referenceQuad = quad(Fixture.panelCorners, width: 480, height: 360)
    static let liveQuad = quad(Fixture.liveCorners, width: 640, height: 480)

    static func reference(_ image: SyntheticGray = Fixture.panel, orientation: PhotoOrientation = .up,
                          quad: PanelQuad = referenceQuad, data: Data? = nil) throws -> PanelReference {
        let stored: CGImagePropertyOrientation = switch orientation {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
        let photo = PanelPhoto(data: data ?? image.pngData(storedFor: stored),
                               pixelSize: PixelSize(width: image.width, height: image.height),
                               orientation: orientation, timestamp: Date(timeIntervalSince1970: 0))
        return try PanelReference(photo: photo, detection: PanelDetection(
            referencePhotoID: photo.id, quad: quad, map: MockSurfaceMaps.microwave))
    }

    static func camera(_ image: SyntheticGray, orientation: CGImagePropertyOrientation = .up) -> CameraFrame {
        CameraFrame(pixelBuffer: image.pixelBuffer(storedFor: orientation), timestamp: Date(), orientation: orientation)
    }
}

func expectQuad(_ quad: PanelQuad?, near truth: PanelQuad, within tolerance: Double,
                sourceLocation: SourceLocation = #_sourceLocation) {
    guard let quad else {
        Issue.record("expected a quad", sourceLocation: sourceLocation)
        return
    }
    let found = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
    let expected = [truth.topLeft, truth.topRight, truth.bottomRight, truth.bottomLeft]
    for (corner, target) in zip(found, expected) {
        let error = hypot(corner.x - target.x, corner.y - target.y)
        #expect(error <= tolerance, "corner \(corner) is \(error) from \(target)", sourceLocation: sourceLocation)
    }
}

/// Runs a scripted action once, from inside the tracker's preparation seam.
actor Interruption {
    private var action: (@Sendable () async -> Void)?
    func set(_ action: @escaping @Sendable () async -> Void) { self.action = action }
    func run() async {
        guard let action else { return }
        self.action = nil
        await action()
    }
}

/// Delivers fixed images on demand, each stamped with its capture time when
/// pulled, as a live camera would (the quality evaluator rejects stale frames).
final class FixedCamera: CameraFrameSource, @unchecked Sendable {
    private let buffers: [CVPixelBuffer]
    private let orientation: CGImagePropertyOrientation
    private let lock = NSLock()
    private var frames: [CameraFrame] = []

    init(buffers: [CVPixelBuffer], orientation: CGImagePropertyOrientation) {
        self.buffers = buffers
        self.orientation = orientation
    }

    var delivered: [CameraFrame] { lock.withLock { frames } }

    func cameraFrames() async -> AsyncStream<CameraFrame> {
        AsyncStream(unfolding: { [self] in
            lock.withLock {
                guard frames.count < buffers.count else { return nil }
                let frame = CameraFrame(pixelBuffer: buffers[frames.count], timestamp: Date(), orientation: orientation)
                frames.append(frame)
                return frame
            }
        })
    }
}

final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [LiveTrackingSample] = []
    func append(_ sample: LiveTrackingSample) { lock.withLock { samples.append(sample) } }
    var all: [LiveTrackingSample] { lock.withLock { samples } }
}
