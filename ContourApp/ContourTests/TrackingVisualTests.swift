import ContourCore
import CoreVideo
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Tracking visual integration")
struct TrackingVisualTests {
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

nonisolated private struct UIThreadProbe: TrackingFrameProcessor {
    private static func threadConfidence() -> Double { Thread.isMainThread ? 0 : 1 }
    nonisolated(nonsending) func process(_ frame: CameraFrame) async -> TrackingDiagnostics {
        TrackingDiagnostics(timestamp: frame.timestamp, confidence: Self.threadConfidence(),
                            status: .notDetected)
    }
}
