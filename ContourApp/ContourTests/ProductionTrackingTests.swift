import ContourCore
import ContourMocks
import CoreImage
import CoreVideo
import Foundation
import Testing
import Tracking
import UIKit
@testable import ContourApp

@MainActor @Suite("Production tracking composition")
struct ProductionTrackingTests {
    @Test("Each selected production mode supplies real same-frame evidence", arguments: PanelTrackingMethod.allCases)
    func realModes(method: PanelTrackingMethod) async throws {
        let fixture = try ProductionFixture()
        let samples = ProductionSamples()
        let session = try GuidanceSessionFactories.production(fixture.camera, method,
            FeatureTrackingOptions(), { samples.append($0) })
        #if targetEnvironment(simulator)
        // iOS 27's Vision TrackRectangleRequest crashes inside Vision on this
        // simulator. Construct the real factory here; exercise its frames on device.
        if method == .vision { await session.stop(); return }
        #endif
        await session.use(fixture.reference)
        for await _ in session.frames() {}
        let sample = try #require(samples.last)
        #expect(sample.cameraFrame.timestamp == sample.frame.timestamp)
        if method == .vision {
            #expect(sample.featureDiagnostics == nil)
            #expect(sample.hybridDiagnostics == nil)
        } else {
            #expect(sample.featureDiagnostics != nil)
            #expect(sample.registrationError == nil)
            if method == .hybrid {
                #expect(sample.hybridDiagnostics?.source == (sample.panelQuad == nil ? .unavailable : .visual))
                #expect(sample.hybridDiagnostics?.calibrationReady == false)
            }
        }
        await session.stop()
    }

    @Test("The phone pipeline installs hybrid and a real factory rather than the baseline Vision-only factory")
    func phoneDefaults() async throws {
        let pipeline = ContourPipeline.live(camera: CameraService())
        #expect(pipeline.trackingMethod == .hybrid)
        let fixture = try ProductionFixture()
        let independent = try pipeline.sessionFactory(fixture.camera, .features,
            FeatureTrackingOptions(excludeHighlights: false, normalizeContrast: true), nil)
        await independent.stop()
    }

    @Test("Factory calls keep reference state independent and honor preprocessing options",
          arguments: [PanelTrackingMethod.features, .hybrid])
    func independentOptions(method: PanelTrackingMethod) async throws {
        let fixture = try ProductionFixture()
        let firstSamples = ProductionSamples(), secondSamples = ProductionSamples()
        let first = try GuidanceSessionFactories.production(fixture.camera, method,
            FeatureTrackingOptions(excludeHighlights: true), { firstSamples.append($0) })
        let second = try GuidanceSessionFactories.production(fixture.camera, method,
            FeatureTrackingOptions(excludeHighlights: false), { secondSamples.append($0) })
        await first.use(fixture.reference)
        await second.use(fixture.reference)
        await first.stop()
        for await _ in second.frames() {}
        #expect(secondSamples.last?.featureDiagnostics?.excludedHighlightFraction == 0)
        for await _ in first.frames() {}
        #expect(firstSamples.last?.featureDiagnostics?.excludedHighlightFraction ?? 0 > 0)
        await first.stop(); await second.stop()
    }
}

@MainActor private struct ProductionFixture {
    let camera: ProductionCamera
    let reference: PanelReference
    init() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            var seed: UInt64 = 7
            for _ in 0..<1200 {
                seed = seed &* 6364136223846793005 &+ 1
                let x = Int(seed >> 32) % 480 + 16
                seed = seed &* 6364136223846793005 &+ 1
                let y = Int(seed >> 32) % 480 + 16
                (seed & 1 == 0 ? UIColor.black : UIColor.white).setFill()
                context.fill(CGRect(x: x, y: y, width: 6, height: 8))
            }
            UIColor.white.setFill(); context.fill(CGRect(x: 180, y: 180, width: 70, height: 70))
        }
        let photo = PanelPhoto(data: try #require(image.pngData()), pixelSize: PixelSize(width: 512, height: 512), timestamp: Date())
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.05, y: 0.05), topRight: ImagePoint(x: 0.95, y: 0.05),
            bottomRight: ImagePoint(x: 0.95, y: 0.95), bottomLeft: ImagePoint(x: 0.05, y: 0.95))
        reference = try PanelReference(photo: photo, detection: PanelDetection(referencePhotoID: photo.id,
            quad: quad, map: MockSurfaceMaps.microwave))
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 512, 512, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CIContext().render(CIImage(cgImage: try #require(image.cgImage)), to: pixels)
        camera = ProductionCamera(pixels: pixels)
    }
}

@MainActor private final class ProductionCamera: CameraControl {
    let status = CameraStatus()
    let usesWorldTracking = false
    nonisolated let storedFrame: CameraFrame
    init(pixels: CVPixelBuffer) { storedFrame = CameraFrame(pixelBuffer: pixels, timestamp: Date()) }
    func start() async throws {}
    func stop() async {}
    func retry() async { status.revision += 1 }
    func setExposureBias(_ value: Float) async throws -> Float? { value }
    func cameraFrames() async -> AsyncStream<CameraFrame> {
        let frame = CameraFrame(pixelBuffer: storedFrame.pixelBuffer, timestamp: Date())
        return AsyncStream { $0.yield(frame); $0.finish() }
    }
}

private final class ProductionSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LiveTrackingSample?
    func append(_ sample: LiveTrackingSample) { lock.withLock { value = sample } }
    var last: LiveTrackingSample? { lock.withLock { value } }
}
