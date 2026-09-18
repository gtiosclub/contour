import CoreVideo
import Foundation
import Testing
@testable import Tracking

@Test("Scaffold accepts an image without inventing a fingertip")
func scaffoldDiagnostics() async throws {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 8,
                                   kCVPixelFormatType_32BGRA, nil, &buffer)
    #expect(status == kCVReturnSuccess)
    let frame = CameraFrame(pixelBuffer: try #require(buffer),
                            timestamp: Date(timeIntervalSince1970: 123))
    let result = await UnimplementedFrameProcessor().process(frame)
    #expect(result.timestamp == frame.timestamp)
    #expect(result.fingertip == nil)
    #expect(result.status == .unimplemented)
}
