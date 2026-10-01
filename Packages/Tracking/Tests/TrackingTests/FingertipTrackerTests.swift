import ContourCore
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import Tracking

@Suite("Image-space fingertip detection")
struct FingertipTrackerTests {
    @Test("Vision y-up becomes image y-down and preserves capture time")
    func imageCoordinates() async throws {
        let tracker = FingertipTracker { _ in
            FingertipJoint(x: 0.25, y: 0.75, confidence: 0.8)
        }
        let observation = try await tracker.detect(in: frame(at: 123))
        #expect(observation.timestamp == Date(timeIntervalSince1970: 123))
        #expect(observation.fingertip == ImagePoint(x: 0.25, y: 0.25))
        #expect(observation.confidence == 0.8)
    }

    @Test("Each call uses its supplied frame, including orientation")
    func freshFrames() async throws {
        let tracker = FingertipTracker { frame in
            #expect(frame.orientation == .right)
            return FingertipJoint(x: frame.timestamp.timeIntervalSince1970 / 100,
                                 y: 0.5, confidence: 0.9)
        }
        let first = try await tracker.detect(in: frame(at: 10, orientation: .right))
        let second = try await tracker.detect(in: frame(at: 20, orientation: .right))
        #expect(first.fingertip?.x == 0.1)
        #expect(second.fingertip?.x == 0.2)
        #expect(second.timestamp == Date(timeIntervalSince1970: 20))
    }

    @Test("Missing or unusable joints never become an overlay point", arguments: [
        nil,
        FingertipJoint(x: 0.2, y: 0.7, confidence: 0.3),
        FingertipJoint(x: 0.2, y: 0.7, confidence: 0),
        FingertipJoint(x: .nan, y: 0.7, confidence: 0.9),
        FingertipJoint(x: 0.2, y: .infinity, confidence: 0.9),
        FingertipJoint(x: 0.2, y: 0.7, confidence: .nan),
        FingertipJoint(x: 0.2, y: 0.7, confidence: 1.1),
        FingertipJoint(x: -0.1, y: 0.7, confidence: 0.9),
        FingertipJoint(x: 0.2, y: 1.1, confidence: 0.9),
    ] as [FingertipJoint?])
    func unusableJoint(joint: FingertipJoint?) async throws {
        let tracker = FingertipTracker { _ in joint }
        let result = await FingertipFrameProcessor(tracker: tracker).process(try frame(at: 123))
        #expect(result.status == .notDetected)
        #expect(result.fingertip == nil)
        #expect(result.confidence == nil)
        #expect(result.timestamp == Date(timeIntervalSince1970: 123))
    }

    @Test("Image edges remain valid", arguments: [0.0, 1.0])
    func imageEdges(x: Double) async throws {
        let tracker = FingertipTracker { _ in
            FingertipJoint(x: x, y: 1, confidence: 0.31)
        }
        let observation = try await tracker.detect(in: frame(at: 0))
        #expect(observation.fingertip == ImagePoint(x: x, y: 0))
    }

    @Test("Loss and re-entry replace the previous point")
    func noStaleDetection() async throws {
        let tracker = FingertipTracker { frame in
            frame.timestamp.timeIntervalSince1970 == 2 ? nil
                : FingertipJoint(x: 0.2, y: 0.7, confidence: 0.9)
        }
        let processor = FingertipFrameProcessor(tracker: tracker)
        let detected = await processor.process(try frame(at: 1))
        let missing = await processor.process(try frame(at: 2))
        let recovered = await processor.process(try frame(at: 3))
        #expect(detected.status == .detected)
        #expect(detected.confidence == 0.9)
        #expect(missing.status == .notDetected)
        #expect(missing.fingertip == nil)
        #expect(missing.timestamp == Date(timeIntervalSince1970: 2))
        #expect(recovered.status == .detected)
        #expect(recovered.fingertip != nil)
    }

    @Test("Vision failure clears diagnostics for that frame")
    func processingFailure() async throws {
        let tracker = FingertipTracker { _ in throw DetectionFailure.failed }
        let result = await FingertipFrameProcessor(tracker: tracker).process(try frame(at: 123))
        #expect(result.status == .notDetected)
        #expect(result.fingertip == nil)
        #expect(result.confidence == nil)
        #expect(result.timestamp == Date(timeIntervalSince1970: 123))
    }

    private enum DetectionFailure: Error { case failed }

    private func frame(at seconds: TimeInterval,
                       orientation: CGImagePropertyOrientation = .up) throws -> CameraFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                        kCVPixelFormatType_32BGRA, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        return CameraFrame(pixelBuffer: try #require(buffer),
                           timestamp: Date(timeIntervalSince1970: seconds),
                           orientation: orientation)
    }
}
