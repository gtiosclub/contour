import ContourFeatureMatcher
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Reusable synthetic fixtures for the feature-tracking tests: label-like
// panels, known perspective warps, and camera-shaped inputs built from them.

/// A deterministic 8-bit grayscale image, optionally with padded rows.
struct SyntheticGray {
    let width: Int
    let height: Int
    var bytesPerRow: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, value: UInt8 = 0) {
        self.width = width
        self.height = height
        bytesPerRow = width
        pixels = [UInt8](repeating: value, count: width * height)
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * bytesPerRow + x] }
        set { pixels[y * bytesPerRow + x] = newValue }
    }

    func withImage<T>(_ body: (UnsafePointer<CFTGrayImage>) -> T) -> T {
        pixels.withUnsafeBufferPointer { buffer in
            var image = CFTGrayImage(pixels: buffer.baseAddress, width: Int32(width), height: Int32(height),
                                     bytesPerRow: Int32(bytesPerRow))
            return body(&image)
        }
    }

    /// Label-like clutter: many small high-contrast blocks, bars and dots.
    static func textured(width: Int, height: Int, seed: UInt64) -> SyntheticGray {
        var rng = SplitMix64(seed: seed)
        var image = SyntheticGray(width: width, height: height, value: UInt8(rng.next(in: 90...170)))
        for _ in 0..<(width * height / 900) {
            let w = rng.next(in: 4...28), h = rng.next(in: 4...22)
            let x = rng.next(in: 0...(width - w)), y = rng.next(in: 0...(height - h))
            let value = UInt8(rng.next(in: 0...1) == 0 ? rng.next(in: 0...60) : rng.next(in: 195...255))
            if rng.next(in: 0...3) == 0 {
                image.disc(cx: x + w / 2, cy: y + h / 2, r: min(w, h) / 2, value: value)
            } else {
                image.fill((x, y, w, h), value: value)
            }
        }
        return image
    }

    /// A panel of one identical button design repeated on a uniform face.
    static func repeatedControls(width: Int, height: Int) -> SyntheticGray {
        var image = SyntheticGray(width: width, height: height, value: 140)
        for row in 0..<5 {
            for column in 0..<6 {
                let x = 52 + column * 64, y = 42 + row * 56
                image.fill((x, y, 44, 34), value: 30)
                image.fill((x + 8, y + 8, 12, 6), value: 230)
                image.fill((x + 24, y + 18, 12, 8), value: 230)
                image.disc(cx: x + 14, cy: y + 24, r: 4, value: 230)
            }
        }
        return image
    }

    mutating func fill(_ rect: (Int, Int, Int, Int), value: UInt8) {
        let (x, y, w, h) = rect
        for row in max(0, y)..<min(height, y + h) {
            for column in max(0, x)..<min(width, x + w) { self[column, row] = value }
        }
    }

    mutating func disc(cx: Int, cy: Int, r: Int, value: UInt8) {
        guard r > 0 else { return }
        for row in max(0, cy - r)...min(height - 1, cy + r) {
            for column in max(0, cx - r)...min(width - 1, cx + r)
            where (column - cx) * (column - cx) + (row - cy) * (row - cy) <= r * r {
                self[column, row] = value
            }
        }
    }

    func crop(x: Int, y: Int, width w: Int, height h: Int) -> SyntheticGray {
        var out = SyntheticGray(width: w, height: h)
        for row in 0..<h { for column in 0..<w { out[column, row] = self[x + column, y + row] } }
        return out
    }

    mutating func paste(_ patch: SyntheticGray, x: Int, y: Int) {
        for row in 0..<patch.height where y + row < height {
            for column in 0..<patch.width where x + column < width { self[x + column, y + row] = patch[column, row] }
        }
    }

    func padded(by extra: Int) -> SyntheticGray {
        var out = SyntheticGray(width: width, height: height)
        out.bytesPerRow = width + extra
        out.pixels = [UInt8](repeating: 77, count: out.bytesPerRow * height)
        for row in 0..<height { for column in 0..<width { out[column, row] = self[column, row] } }
        return out
    }

    /// Draws the `source` quad region into `destination` with bilinear sampling.
    mutating func warp(_ source: SyntheticGray, from sourceQuad: [CFTPoint], to destination: [CFTPoint]) {
        let inverse = Homography(from: destination, to: sourceQuad)
        let minX = Int(destination.map(\.x).min()!), maxX = Int(destination.map(\.x).max()!.rounded(.up))
        let minY = Int(destination.map(\.y).min()!), maxY = Int(destination.map(\.y).max()!.rounded(.up))
        let sx = sourceQuad.map { Double($0.x) }, sy = sourceQuad.map { Double($0.y) }
        for row in max(0, minY)...min(height - 1, maxY) {
            for column in max(0, minX)...min(width - 1, maxX) {
                let (u, v) = inverse.apply(Double(column), Double(row))
                // The synthetic source quads are axis-aligned rectangles.
                guard u >= sx.min()!, u <= sx.max()! - 1, v >= sy.min()!, v <= sy.max()! - 1 else { continue }
                let x0 = Int(u), y0 = Int(v), fx = u - Double(x0), fy = v - Double(y0)
                let top = Double(source[x0, y0]) * (1 - fx) + Double(source[x0 + 1, y0]) * fx
                let bottom = Double(source[x0, y0 + 1]) * (1 - fx) + Double(source[x0 + 1, y0 + 1]) * fx
                self[column, row] = UInt8((top * (1 - fy) + bottom * fy).rounded())
            }
        }
    }
}

/// The 3×3 projective map taking four points onto four others (h22 = 1).
struct Homography {
    let h: [Double]

    init(h: [Double]) { self.h = h }

    init(from a: [CFTPoint], to b: [CFTPoint]) {
        var m = [[Double]]()
        for i in 0..<4 {
            let x = Double(a[i].x), y = Double(a[i].y), u = Double(b[i].x), v = Double(b[i].y)
            m.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            m.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        for column in 0..<8 {
            let pivot = (column..<8).max { abs(m[$0][column]) < abs(m[$1][column]) }!
            m.swapAt(column, pivot)
            for row in 0..<8 where row != column {
                let factor = m[row][column] / m[column][column]
                for k in column...8 { m[row][k] -= factor * m[column][k] }
            }
        }
        h = (0..<8).map { m[$0][8] / m[$0][$0] } + [1]
    }

    func w(_ x: Double, _ y: Double) -> Double { h[6] * x + h[7] * y + h[8] }

    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        let w = w(x, y)
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

// MARK: - Camera-shaped inputs

extension SyntheticGray {
    /// Nearest-neighbour enlargement: the same picture at a camera's resolution.
    func upscaled(by factor: Int) -> SyntheticGray {
        var out = SyntheticGray(width: width * factor, height: height * factor)
        for row in 0..<out.height {
            for column in 0..<out.width { out[column, row] = self[column / factor, row / factor] }
        }
        return out
    }

    func cgImage() -> CGImage {
        let data = Data(pixels) as CFData
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// PNG bytes stored so that applying `orientation` shows this image upright.
    func pngData(storedFor orientation: CGImagePropertyOrientation = .up) -> Data {
        let stored = Self.context.createCGImage(storedImage(for: orientation),
                                                from: storedImage(for: orientation).extent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, stored, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A BGRA camera buffer stored so that `orientation` shows this image upright.
    func pixelBuffer(storedFor orientation: CGImagePropertyOrientation = .up) -> CVPixelBuffer {
        let stored = storedImage(for: orientation)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(stored.extent.width), Int(stored.extent.height),
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        Self.context.render(stored, to: buffer!, bounds: stored.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer!
    }

    private func storedImage(for orientation: CGImagePropertyOrientation) -> CIImage {
        let inverse: CGImagePropertyOrientation = switch orientation {
        case .right: .left
        case .left: .right
        default: orientation
        }
        let image = CIImage(cgImage: cgImage()).oriented(inverse)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static let context = CIContext()
}

// MARK: - Lighting

extension SyntheticGray {
    /// The same scene in dim, flat light: every value squeezed into `range` levels.
    func dimmed(range: Int, floor: Int = 118) -> SyntheticGray {
        var out = self
        out.pixels = pixels.map { UInt8(floor + Int($0) * range / 255) }
        return out
    }

    /// Clipped specular hotspots: a rectangle and a round spot.
    static let glare: [(rect: (Int, Int, Int, Int)?, disc: (Int, Int, Int)?)] = [
        ((220, 150, 90, 70), nil), (nil, (400, 300, 30)),
    ]

    func withGlare() -> SyntheticGray {
        var out = self
        for spot in Self.glare {
            if let rect = spot.rect { out.fill(rect, value: 255) }
            if let (x, y, r) = spot.disc { out.disc(cx: x, cy: y, r: r, value: 255) }
        }
        return out
    }

    /// Distance from `point` to the nearest glare pixel (0 inside).
    static func distanceToGlare(_ point: CFTPoint) -> Float {
        glare.map { spot -> Float in
            if let (x, y, w, h) = spot.rect {
                let dx = max(Float(x) - point.x, 0, point.x - Float(x + w - 1))
                let dy = max(Float(y) - point.y, 0, point.y - Float(y + h - 1))
                return hypot(dx, dy)
            }
            let (x, y, r) = spot.disc!
            return max(0, hypot(point.x - Float(x), point.y - Float(y)) - Float(r))
        }.min()!
    }
}
