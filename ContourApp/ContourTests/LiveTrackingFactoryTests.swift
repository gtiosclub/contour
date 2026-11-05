import ContourCore
import ContourMocks
import CoreVideo
import Foundation
import Testing
import Tracking
import os
import simd
@testable import ContourApp

@MainActor
@Suite("Live tracking factory integration")
struct LiveTrackingFactoryTests {
    @Test("The live factory delivers matching evidence and honors highlight options",
          arguments: [PanelTrackingMethod.features, .hybrid], [true, false])
    func realMatching(method: PanelTrackingMethod, excludeHighlights: Bool) async throws {
        let frame = try texturedFrame()
        let camera = FactoryCamera(frame: frame)
        let captured = OSAllocatedUnfairLock(initialState: [LiveTrackingSample]())
        let source = try GuidanceSessionFactories.production(camera, method,
            FeatureTrackingOptions(excludeHighlights: excludeHighlights, normalizeContrast: true)) { sample in
                captured.withLock { $0.append(sample) }
            }
        await source.use(try reference(frame: frame))
        for await _ in source.frames() { }
        let samples = captured.withLock { $0 }
        let sample = try #require(samples.last)
        #expect(samples.count == 1)
        #expect(sample.cameraFrame.timestamp == frame.timestamp)
        #expect(sample.panelStatus == .tracked)
        // Deliberately old fixture: matching may succeed, but stale geometry
        // must never become live guidance. This avoids wall-clock timing tests.
        #expect(sample.panelQuad == nil)
        #expect(sample.assessment?.reason == .stale)
        #expect(sample.featureDiagnostics?.inlierCount ?? 0 >= 12)
        let fraction = try #require(sample.featureDiagnostics?.excludedHighlightFraction)
        #expect(excludeHighlights ? fraction > 0 : fraction == 0)
        if method == .hybrid {
            #expect(sample.hybridDiagnostics?.source == .unavailable)
            #expect(sample.hybridDiagnostics?.message.contains("no world data") == true)
            #expect(sample.hybridDiagnostics?.calibrationReady == false)
            #expect(sample.hybridDiagnostics?.surfaceSelection == nil)
        } else {
            #expect(sample.hybridDiagnostics == nil)
        }
    }

    @Test("Replacing one factory session's reference cannot invalidate a second session")
    func independentSessions() async throws {
        let frame = try texturedFrame()
        let camera = FactoryCamera(frame: frame)
        let first = try GuidanceSessionFactories.production(camera, .hybrid, FeatureTrackingOptions(), nil)
        let secondSamples = OSAllocatedUnfairLock(initialState: [LiveTrackingSample]())
        let second = try GuidanceSessionFactories.production(camera, .hybrid, FeatureTrackingOptions()) { sample in
            secondSamples.withLock { $0.append(sample) }
        }
        let valid = try reference(frame: frame)
        await first.use(valid)
        await second.use(valid)
        let unreadable = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 400, height: 480), timestamp: Date())
        let invalid = try PanelReference(photo: unreadable, detection: PanelDetection(referencePhotoID: unreadable.id,
            quad: valid.detection.quad, map: MockSurfaceMaps.microwave))
        await first.use(invalid)
        for await _ in first.frames() { }
        for await _ in second.frames() { }
        #expect(await first.registrationError() == .unreadableReferencePhoto)
        #expect(await second.registrationError() == nil)
        let secondSample = try #require(secondSamples.withLock { $0.last })
        #expect(secondSample.hybridDiagnostics?.source == .unavailable)
        #expect(secondSample.hybridDiagnostics?.calibrationReady == false)
        #expect(await second.hybridStatus() == nil, "Natural stream termination retires the session")
    }

    @Test("The hybrid factory passes same-frame AR planes into calibration")
    func synchronizedWorldCalibration() async throws {
        let world = WorldCameraSnapshot(sessionID: UUID(), cameraToWorld: matrix_identity_float4x4,
            intrinsics: simd_float3x3(SIMD3(400, 0, 0), SIMD3(0, 400, 0), SIMD3(240, 200, 1)),
            imageSize: SIMD2(480, 400), normalTracking: true,
            planes: [WorldPlane(transform: simd_float4x4(
                SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, -0.5, 1)),
                extent: SIMD2(2, 2))])
        let frame = try texturedFrame(world: world)
        let samples = OSAllocatedUnfairLock(initialState: [LiveTrackingSample]())
        let source = try GuidanceSessionFactories.production(FactoryCamera(frame: frame), .hybrid,
            FeatureTrackingOptions()) { sample in samples.withLock { $0.append(sample) } }
        await source.use(try reference(frame: frame))
        for await _ in source.frames() { }
        let hybrid = try #require(samples.withLock { $0.last?.hybridDiagnostics })
        #expect(await source.hybridStatus() == nil)
        #expect(hybrid.calibrationFrames == 1)
        #expect(hybrid.surfaceSelection?.detectedPlaneCount == 1)
        #expect(hybrid.surfaceSelection?.fittingPlaneCount == 1)
        #expect(!hybrid.calibrationReady)
    }

    private func reference(frame: CameraFrame) throws -> PanelReference {
        let photo = try PanelPhoto(frame: frame)
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.1), topRight: ImagePoint(x: 0.9, y: 0.1),
                             bottomRight: ImagePoint(x: 0.9, y: 0.9), bottomLeft: ImagePoint(x: 0.1, y: 0.9))
        return try PanelReference(photo: photo, detection: PanelDetection(referencePhotoID: photo.id,
            quad: quad, map: MockSurfaceMaps.microwave))
    }

    /// Fixed high-contrast blocks and clipped highlights, with no external files.
    private func texturedFrame(world: WorldCameraSnapshot? = nil) throws -> CameraFrame {
        let width = 400, height = 480
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var seed: UInt64 = 73
        for y in 0..<height {
            for x in 0..<width {
                // A reproducible pattern with structure on several pixel scales.
                let block = UInt64((x / 8) + (y / 8) * 50)
                seed = block &* 6364136223846793005 &+ 1442695040888963407
                let value: UInt8 = ((x > 140 && x < 190 && y > 150 && y < 210)
                    ? 255 : UInt8(20 + ((seed >> 32) % 200)))
                let offset = y * stride + x * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        return CameraFrame(pixelBuffer: pixels, timestamp: Date(timeIntervalSince1970: 2000), world: world)
    }
}

private struct FactoryCamera: CameraFrameSource {
    let frame: CameraFrame
    func cameraFrames() async -> AsyncStream<CameraFrame> {
        AsyncStream { $0.yield(frame); $0.finish() }
    }
}
