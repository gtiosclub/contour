import ContourCore
import ContourMocks
import CoreVideo
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Shared tracking setup")
struct SharedTrackingSetupTests {
    @Test("Pipeline factory sessions receive reference handoff and report errors without a concrete-source cast")
    func pipelineUsesInjectedSession() async throws {
        let session = SetupSession()
        var selected: PanelTrackingMethod?
        var suppliedOptions: FeatureTrackingOptions?
        let factory: GuidanceSessionFactory = { _, method, options, _ in
            selected = method
            suppliedOptions = options
            return session
        }
        let pipeline = try ContourPipeline.live(camera: SetupCamera(), sessionFactory: factory,
            method: .hybrid, options: FeatureTrackingOptions(excludeHighlights: false, normalizeContrast: true))
        let reference = try reference()
        await pipeline.replaceReference(with: reference)
        await pipeline.guide(to: reference.detection.map.buttons[0])
        #expect(selected == .hybrid)
        #expect(pipeline.trackingMethod == selected)
        #expect(pipeline.featureOptions == suppliedOptions)
        #expect(await session.referenceID == reference.photo.id)
        #expect(pipeline.trackingError != nil)
        #expect(pipeline.hybridStatus?.source == .unavailable)
    }

    @Test("The baseline factory rejects methods whose algorithms have not been implemented")
    func unavailableMethodsAreExplicit() throws {
        let camera = SetupCamera()
        for method in [PanelTrackingMethod.features, .hybrid] {
            #expect(throws: GuidanceSessionFactoryError.unimplemented(method)) {
                try GuidanceSessionFactories.vision(camera, method, FeatureTrackingOptions(), nil)
            }
        }
        _ = try GuidanceSessionFactories.vision(camera, .vision, FeatureTrackingOptions(), nil)
    }

    @Test("Diagnostics uses the injected sample factory and fake camera controls")
    func diagnosticsCanRunIndependently() async throws {
        let camera = SetupCamera()
        var callbackWasSupplied = false
        let factory: GuidanceSessionFactory = { _, _, _, callback in
            callbackWasSupplied = callback != nil
            return SetupSampleSession(onSample: callback)
        }
        let model = TrackingDebugModel(processor: SetupFinger(), sessionFactory: factory)
        await model.run(camera: camera, reference: try reference())
        #expect(camera.startCount == 1)
        #expect(callbackWasSupplied)
        #expect(model.framesProcessed == 1)
    }

    private func reference() throws -> PanelReference {
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 32, height: 24), timestamp: Date())
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.2, y: 0.2), topRight: ImagePoint(x: 0.8, y: 0.2),
            bottomRight: ImagePoint(x: 0.8, y: 0.8), bottomLeft: ImagePoint(x: 0.2, y: 0.8))
        return try PanelReference(photo: photo, detection: PanelDetection(referencePhotoID: photo.id,
            quad: quad, map: MockSurfaceMaps.microwave))
    }
}

private actor SetupSession: GuidanceTrackingSession {
    private(set) var referenceID: UUID?
    func use(_ reference: PanelReference) { referenceID = reference.photo.id }
    func registrationError() -> PanelTrackingError? { .registrationFailed }
    func hybridStatus() -> HybridTrackingDiagnostics? {
        HybridTrackingDiagnostics(mode: .reacquiring, message: "Scripted", calibrationFrames: 0, source: .unavailable)
    }
    nonisolated func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { $0.yield(.lost(at: Date())); $0.finish() }
    }
}

@MainActor
private final class SetupCamera: CameraControl {
    let status = CameraStatus()
    let usesWorldTracking = false
    private(set) var startCount = 0
    func start() async throws { await MainActor.run { startCount += 1 } }
    func stop() async {}
    func retry() async { status.revision += 1 }
    func setExposureBias(_ value: Float) async throws -> Float? { nil }
    func cameraFrames() async -> AsyncStream<CameraFrame> { AsyncStream { $0.finish() } }
}

private struct SetupSampleSession: GuidanceTrackingSession {
    let onSample: (@Sendable (LiveTrackingSample) -> Void)?
    func use(_ reference: PanelReference) async {}
    func registrationError() async -> PanelTrackingError? { nil }
    func hybridStatus() async -> HybridTrackingDiagnostics? { nil }
    func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { continuation in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continuation.finish(); return }
            let frame = CameraFrame(pixelBuffer: buffer, timestamp: Date())
            let output = TrackingFrame.lost(at: frame.timestamp)
            onSample?(LiveTrackingSample(cameraFrame: frame, frame: output, panelQuad: nil,
                imageFingertip: nil, assessment: nil, registrationError: nil))
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private struct SetupFinger: TrackingFrameProcessor {
    func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        TrackingDiagnostics(timestamp: frame.timestamp, status: .notDetected)
    }
}
