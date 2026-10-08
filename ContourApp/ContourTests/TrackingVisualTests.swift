import ContourCore
import CoreVideo
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Tracking visual integration")
struct TrackingVisualTests {
    @Test("Panel loss does not suppress independent image-space fingertip diagnostics")
    func fingertipRemainsVisibleWithoutPanel() async throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date())
        let model = TrackingDebugModel(processor: RecordedFingerProcessor())
        let result = await model.visualFingertip(in: frame, panelTracked: false, fingertip: nil)
        #expect(result.fingertip == ImagePoint(x: 0.4, y: 0.6))
        #expect(result.status == .detected)
        #expect(result.timestamp == frame.timestamp)
    }

    @Test("A usable panel keeps its same-frame fused fingertip observation")
    func fingertipUsesFusionWhenPanelIsUsable() async throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date())
        let model = TrackingDebugModel(processor: RecordedFingerProcessor())
        let tip = ImagePoint(x: 0.2, y: 0.3)
        let result = await model.visualFingertip(in: frame, panelTracked: true, fingertip: tip)
        #expect(result.fingertip == tip)
        let absent = await model.visualFingertip(in: frame, panelTracked: true, fingertip: nil)
        #expect(absent.fingertip == nil)
        #expect(absent.status == .notDetected)
    }

    @Test("Diagnostics runs detector work away from the UI thread")
    func diagnosticsDoesNotProcessOnUIThread() async throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        let model = TrackingDebugModel(processor: UIThreadProbe())
        let result = await model.process(CameraFrame(pixelBuffer: pixels, timestamp: Date()))
        #expect(result.confidence == 1, "Detector ran on the main thread")
    }
}

nonisolated private struct RecordedFingerProcessor: TrackingFrameProcessor {
    func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        TrackingDiagnostics(timestamp: frame.timestamp, fingertip: ImagePoint(x: 0.4, y: 0.6),
                            confidence: 0.9, status: .detected)
    }
}

nonisolated private struct UIThreadProbe: TrackingFrameProcessor {
    private static func threadConfidence() -> Double { Thread.isMainThread ? 0 : 1 }
    nonisolated(nonsending) func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        TrackingDiagnostics(timestamp: frame.timestamp, confidence: Self.threadConfidence(),
                            status: .notDetected)
    }
}
