//
//  PanelPhotoCaptureTests.swift
//  ContourTests
//
//  The camera-frame-to-PanelPhoto step that feeds Surface Understanding.
//

import ContourCore
import CoreVideo
import Foundation
import ImageIO
import Testing
import Tracking
@testable import ContourApp

/// A grey BGRA buffer, the format CameraService delivers.
private func frame(width: Int, height: Int, orientation: CGImagePropertyOrientation = .up) throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
    CVPixelBufferUnlockBaseAddress(pixels, [])
    return CameraFrame(pixelBuffer: pixels, timestamp: Date(timeIntervalSince1970: 1_000), orientation: orientation)
}

@Test("a camera frame becomes a JPEG PanelPhoto with the frame's size, orientation and time")
func cameraFrameBecomesPanelPhoto() throws {
    let source = try frame(width: 72, height: 128)

    let photo = try PanelPhoto(frame: source)

    #expect(photo.pixelSize == PixelSize(width: 72, height: 128))
    #expect(photo.orientation == .up)
    #expect(photo.timestamp == source.timestamp)

    // The data decodes to an image of the same size.
    let image = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 72)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 128)
}

@Test("a mirrored camera frame is refused rather than mislabelled")
func mirroredFrameThrows() throws {
    let source = try frame(width: 8, height: 8, orientation: .upMirrored)

    #expect(throws: PanelPhotoCaptureError.self) { _ = try PanelPhoto(frame: source) }
}
