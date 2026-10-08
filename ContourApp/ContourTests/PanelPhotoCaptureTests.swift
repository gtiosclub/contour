//
//  PanelPhotoCaptureTests.swift
//  ContourTests
//
//  The camera-frame-to-PanelPhoto step that feeds Surface Understanding.
//

import ContourCore
import CoreVideo
import CoreImage
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

@Test("Capture preserves all four image corners rather than the preview crop")
func capturePreservesCornerLandmarks() throws {
    let source = try frame(width: 72, height: 128)
    CVPixelBufferLockBaseAddress(source.pixelBuffer, [])
    let pixels = try #require(CVPixelBufferGetBaseAddress(source.pixelBuffer))
        .assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(source.pixelBuffer)
    for y in 0..<128 {
        for x in 0..<72 {
            let offset = y * stride + x * 4
            // Top-left red, top-right green, bottom-left blue, bottom-right yellow.
            let color: [UInt8] = y < 64 ? (x < 36 ? [0, 0, 255] : [0, 255, 0])
                : (x < 36 ? [255, 0, 0] : [0, 255, 255])
            for channel in 0..<3 { pixels[offset + channel] = color[channel] }
            pixels[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(source.pixelBuffer, [])
    let photo = try PanelPhoto(frame: source)
    let image = try #require(CIImage(data: photo.data))
    let context = CIContext()
    func sample(_ x: Double, _ y: Double) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return rgba
    }
    // Core Image's y origin is at the bottom, while buffer rows start at the top.
    let red = sample(8, 120), green = sample(64, 120)
    let blue = sample(8, 8), yellow = sample(64, 8)
    #expect(red[0] > 200 && red[1] < 40 && red[2] < 40)
    #expect(green[0] < 40 && green[1] > 200 && green[2] < 40)
    #expect(blue[0] < 40 && blue[1] < 40 && blue[2] > 200)
    #expect(yellow[0] > 200 && yellow[1] > 200 && yellow[2] < 40)
}
