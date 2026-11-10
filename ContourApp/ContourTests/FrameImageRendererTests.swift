//
//  FrameImageRendererTests.swift
//  ContourTests
//
//  The display-only preview copy of a camera frame.
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import Tracking
@testable import ContourApp

/// A BGRA buffer painted red top-left, green top-right, blue bottom-left, yellow bottom-right.
private func cornerFrame(width: Int, height: Int, orientation: CGImagePropertyOrientation) throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
    let pixelBuffer = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let pixels = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            let color: [UInt8] = y < height / 2 ? (x < width / 2 ? [0, 0, 255] : [0, 255, 0])
                : (x < width / 2 ? [255, 0, 0] : [0, 255, 255])
            for channel in 0..<3 { pixels[offset + channel] = color[channel] }
            pixels[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return CameraFrame(pixelBuffer: pixelBuffer, timestamp: Date(timeIntervalSince1970: 1_000), orientation: orientation)
}

/// RGBA of the pixel at (`x`, `y`), measured from the top-left like the buffer.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: 4)
    CIContext().render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: 4,
        bounds: CGRect(x: x, y: image.height - 1 - y, width: 1, height: 1), format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB())
    return rgba
}

@Test("A sideways frame's preview is upright, scaled to a 960-pixel long side, corners turned clockwise")
func previewIsUprightAndScaled() async throws {
    let source = try cornerFrame(width: 1920, height: 1080, orientation: .right)

    let image = try #require(await FrameImageRenderer().previewImage(for: source))

    #expect(image.width == 540 && image.height == 960)
    let topLeft = pixel(image, 20, 20), topRight = pixel(image, 520, 20)
    let bottomLeft = pixel(image, 20, 940), bottomRight = pixel(image, 520, 940)
    #expect(topRight[0] > 200 && topRight[1] < 40 && topRight[2] < 40)          // red
    #expect(bottomRight[0] < 40 && bottomRight[1] > 200 && bottomRight[2] < 40) // green
    #expect(bottomLeft[0] > 200 && bottomLeft[1] > 200 && bottomLeft[2] < 40)   // yellow
    #expect(topLeft[0] < 40 && topLeft[1] < 40 && topLeft[2] > 200)             // blue
}

@Test("A preview never enlarges a frame that is already within the limit")
func previewDoesNotEnlarge() async throws {
    let source = try cornerFrame(width: 640, height: 480, orientation: .up)

    let image = try #require(await FrameImageRenderer().previewImage(for: source))

    #expect(image.width == 640 && image.height == 480)
    let topLeft = pixel(image, 20, 20)
    #expect(topLeft[0] > 200 && topLeft[1] < 40 && topLeft[2] < 40)             // red stays put
}
