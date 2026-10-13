import ContourCore
import ContourMocks
import CoreVideo
import Foundation
import simd
import Testing
import Tracking

@Suite("Shared tracking contracts")
struct TrackingContractTests {
    @Test("Existing camera producers can omit world data; supplied snapshots preserve identity")
    func worldDataIsOptional() throws {
        let frame = try cameraFrame()
        #expect(frame.world == nil)
        let world = WorldCameraSnapshot(sessionID: UUID(), cameraToWorld: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3, imageSize: SIMD2(32, 24), normalTracking: true, planes: [])
        let synchronized = CameraFrame(pixelBuffer: frame.pixelBuffer, timestamp: frame.timestamp,
            orientation: .right, world: world)
        #expect(synchronized.world?.sessionID == world.sessionID)
        #expect(synchronized.timestamp == frame.timestamp)
    }

    @Test("An independent panel implementation receives the reference and emits same-frame loss diagnostics")
    func injectedTrackerWorksWithoutVision() async throws {
        let frame = try cameraFrame()
        let tracker = ContractPanel()
        let samples = ContractSamples()
        let source = LiveTrackingSource(camera: ContractCamera(frame: frame), panelTracker: tracker,
            onSample: { samples.append($0) })
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 32, height: 24), timestamp: frame.timestamp)
        let reference = try PanelReference(photo: photo, detection: PanelDetection(
            referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
        await source.use(reference)
        var frames: [TrackingFrame] = []
        for await output in source.frames() { frames.append(output) }
        #expect(await tracker.referenceID == photo.id)
        #expect(frames.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.frame.trackingQuality == .lost)
        #expect(sample.panelQuad == nil)
        #expect(sample.cameraFrame.timestamp == frame.timestamp)
        #expect(sample.panelStatus == .lost(.notFound))
        #expect(sample.featureDiagnostics?.matchCount == 3)
        #expect(sample.hybridDiagnostics?.source == .unavailable)
        #expect(await source.hybridStatus()?.source == .unavailable)
    }

    private func cameraFrame() throws -> CameraFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        return CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date())
    }
}

private struct ContractCamera: CameraFrameSource {
    let frame: CameraFrame
    func cameraFrames() async -> AsyncStream<CameraFrame> {
        AsyncStream { $0.yield(frame); $0.finish() }
    }
}

private actor ContractPanel: PanelTracking {
    private(set) var referenceID: UUID?
    func startTracking(_ reference: PanelReference) { referenceID = reference.photo.id }
    func stopTracking() { referenceID = nil }
    func track(_ frame: CameraFrame) -> PanelObservation {
        var result = PanelObservation.lost(.notFound, at: frame.timestamp)
        result.featureDiagnostics = FeatureTrackingDiagnostics(referenceFeatures: 40, frameFeatures: 20,
            matchCount: 3, inlierCount: 0, coverage: 0, reprojectionError: .infinity,
            processingMilliseconds: 1, message: "Scripted rejection", inlierPoints: [],
            saturatedFraction: 0, excludedHighlightFraction: 0)
        result.hybridDiagnostics = HybridTrackingDiagnostics(mode: .reacquiring, message: "Scripted loss",
            calibrationFrames: 0, source: .unavailable)
        return result
    }
}

private final class ContractSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [LiveTrackingSample] = []
    func append(_ sample: LiveTrackingSample) { lock.withLock { samples.append(sample) } }
    var first: LiveTrackingSample? { lock.withLock { samples.first } }
}
