import ContourFeatureMatcher
import Foundation
import Testing

/// Exercises the C backend directly on generated images with known geometry.
/// Swift image preparation and normalized coordinates are #82's wrapper.
@Suite("OpenCV feature matcher backend")
struct FeatureMatcherBackendTests {
    static let panel = SyntheticGray.textured(width: 480, height: 360, seed: 7)
    static let panelCorners = [CFTPoint(x: 40, y: 30), CFTPoint(x: 440, y: 30),
                               CFTPoint(x: 440, y: 330), CFTPoint(x: 40, y: 330)]
    /// Where the panel appears in the live frame: tilted, foreshortened, smaller.
    static let liveCorners = [CFTPoint(x: 150, y: 90), CFTPoint(x: 505, y: 125),
                              CFTPoint(x: 470, y: 400), CFTPoint(x: 130, y: 365)]

    static func liveFrame(cover: [(Int, Int, Int, Int)] = []) -> SyntheticGray {
        var frame = SyntheticGray.textured(width: 640, height: 480, seed: 99)
        frame.warp(panel, from: panelCorners, to: liveCorners)
        for rect in cover { frame.fill(rect, value: 128) }
        return frame
    }

    @Test("Registers enough features from the marked panel only")
    func registration() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Self.panel, corners: Self.panelCorners)
        #expect(info.referenceFeatures >= 40)
        #expect(cft_reference_feature_count(tracker.handle) == info.referenceFeatures)
        #expect(cft_active_feature_count(tracker.handle) == info.referenceFeatures)
    }

    @Test("Finds a perspective view of the panel with accurate corners")
    func perspective() throws {
        let tracker = try Tracker()
        try tracker.register(Self.panel, corners: Self.panelCorners)
        let (status, result) = tracker.match(Self.liveFrame())
        #expect(status == CFT_STATUS_OK)
        #expect(result.lossReason == CFT_LOSS_NONE)
        expectCorners(result, near: Self.liveCorners, within: 3)
        #expect(result.confidence > 0.6 && result.confidence <= 0.95)
        #expect(result.inlierCount >= 20)
        #expect(result.coverage >= 0.5)
        #expect(result.reprojectionError < 2.5)
        #expect(cft_copy_inlier_points(tracker.handle, nil, 0) == result.inlierCount)
    }

    @Test("A covered corner and a covered target still yield all four corners")
    func partialOcclusion() throws {
        let tracker = try Tracker()
        try tracker.register(Self.panel, corners: Self.panelCorners)
        // A hand over the top-left corner and a thumb over the middle of the panel.
        let frame = Self.liveFrame(cover: [(100, 60, 170, 130), (290, 220, 70, 60)])
        let (status, result) = tracker.match(frame)
        #expect(status == CFT_STATUS_OK)
        expectCorners(result, near: Self.liveCorners, within: 4)
    }

    @Test("Recovers against the original reference after the panel is lost")
    func recovery() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Self.panel, corners: Self.panelCorners)

        let covered = tracker.match(Self.liveFrame(cover: [(100, 60, 430, 360)]))
        #expect(covered.0 == CFT_STATUS_LOST)
        expectZeroCorners(covered.1)
        #expect(covered.1.confidence == 0)

        let unrelated = tracker.match(SyntheticGray.textured(width: 640, height: 480, seed: 1234))
        #expect(unrelated.0 == CFT_STATUS_LOST)

        // Neither lost frame altered the reference.
        #expect(cft_reference_feature_count(tracker.handle) == info.referenceFeatures)
        let (status, result) = tracker.match(Self.liveFrame())
        #expect(status == CFT_STATUS_OK)
        expectCorners(result, near: Self.liveCorners, within: 3)
    }

    @Test("Rejects an unrelated scene without reporting corners")
    func unrelatedImage() throws {
        let tracker = try Tracker()
        try tracker.register(Self.panel, corners: Self.panelCorners)
        for seed in [11, 23, 57] as [UInt64] {
            let (status, result) = tracker.match(SyntheticGray.textured(width: 640, height: 480, seed: seed))
            #expect(status == CFT_STATUS_LOST)
            #expect(result.lossReason != CFT_LOSS_NONE)
            #expect(result.confidence == 0)
            expectZeroCorners(result)
        }
    }

    @Test("Repeated identical controls are rejected rather than guessed")
    func repeatedControls() throws {
        let grid = SyntheticGray.repeatedControls(width: 480, height: 360)
        let tracker = try Tracker()
        do {
            try tracker.register(grid, corners: Self.panelCorners)
        } catch let status as CFTStatus {
            #expect(status == CFT_STATUS_INSUFFICIENT_FEATURES)
            return
        }
        var frame = SyntheticGray.textured(width: 640, height: 480, seed: 99)
        frame.warp(grid, from: Self.panelCorners, to: Self.liveCorners)
        let (status, result) = tracker.match(frame)
        #expect(status == CFT_STATUS_LOST)
        expectZeroCorners(result)
    }

    @Test("One control repeated across a frame cannot pass as the panel")
    func repeatedPatchFromReference() throws {
        let tracker = try Tracker()
        try tracker.register(Self.panel, corners: Self.panelCorners)
        var frame = SyntheticGray.textured(width: 640, height: 480, seed: 5)
        let patch = Self.panel.crop(x: 200, y: 150, width: 60, height: 50)
        for row in 0..<7 {
            for column in 0..<8 { frame.paste(patch, x: 20 + column * 76, y: 20 + row * 64) }
        }
        let (status, result) = tracker.match(frame)
        #expect(status == CFT_STATUS_LOST)
        expectZeroCorners(result)
    }

    @Test("Row padding is honoured")
    func paddedRows() throws {
        let tracker = try Tracker()
        try tracker.register(Self.panel.padded(by: 13), corners: Self.panelCorners)
        let (status, result) = tracker.match(Self.liveFrame().padded(by: 29))
        #expect(status == CFT_STATUS_OK)
        expectCorners(result, near: Self.liveCorners, within: 3)
    }

    @Test("Invalid buffers and arguments fail explicitly and leave no evidence")
    func invalidInputs() throws {
        let tracker = try Tracker()
        #expect(tracker.match(Self.liveFrame()).0 == CFT_STATUS_NOT_REGISTERED)

        let corners = Self.panelCorners
        var image = CFTGrayImage(pixels: nil, width: 480, height: 360, bytesPerRow: 480)
        #expect(cft_register_reference(tracker.handle, &image, corners, nil) == CFT_STATUS_INVALID_BUFFER)
        #expect(throws: CFTStatus.self) { try tracker.register(SyntheticGray(width: 16, height: 360), corners: corners) }
        #expect(throws: CFTStatus.self) { try tracker.register(SyntheticGray(width: 5000, height: 40), corners: corners) }

        let nonfinite = [CFTPoint(x: .nan, y: 30)] + corners.dropFirst()
        #expect(throws: CFT_STATUS_INVALID_ARGUMENT) { try tracker.register(Self.panel, corners: nonfinite) }
        let folded = [corners[0], corners[2], corners[1], corners[3]]
        #expect(throws: CFT_STATUS_INVALID_ARGUMENT) { try tracker.register(Self.panel, corners: folded) }
        let outside = [CFTPoint(x: -40, y: 30)] + corners.dropFirst()
        #expect(throws: CFT_STATUS_INVALID_ARGUMENT) { try tracker.register(Self.panel, corners: outside) }
        #expect(throws: CFT_STATUS_INSUFFICIENT_FEATURES) {
            try tracker.register(SyntheticGray(width: 480, height: 360, value: 90), corners: corners)
        }
        #expect(cft_register_reference(nil, &image, corners, nil) == CFT_STATUS_INVALID_ARGUMENT)

        try tracker.register(Self.panel, corners: corners)
        #expect(tracker.match(Self.liveFrame()).0 == CFT_STATUS_OK)
        #expect(cft_copy_inlier_points(tracker.handle, nil, 0) > 0)

        let frame = Self.liveFrame()
        frame.pixels.withUnsafeBufferPointer { buffer in
            var short = CFTGrayImage(pixels: buffer.baseAddress, width: 640, height: 480, bytesPerRow: 600)
            var result = CFTMatchResult()
            #expect(cft_match_frame(tracker.handle, &short, &result) == CFT_STATUS_INVALID_BUFFER)
            expectZeroCorners(result)
        }
        #expect(cft_copy_inlier_points(tracker.handle, nil, 0) == 0)
        #expect(cft_copy_inlier_feature_ids(tracker.handle, nil, 0) == 0)
        #expect(cft_match_frame(tracker.handle, nil, nil) == CFT_STATUS_INVALID_BUFFER)
        #expect(cft_match_frame(nil, nil, nil) == CFT_STATUS_INVALID_ARGUMENT)

        cft_reset(tracker.handle)
        #expect(tracker.match(Self.liveFrame()).0 == CFT_STATUS_NOT_REGISTERED)
    }

    @Test("Invalid configuration is refused")
    func invalidConfig() {
        var config = CFTConfig()
        cft_default_config(&config)
        config.ratioTest = 1.5
        #expect(cft_create(&config) == nil)
        cft_default_config(&config)
        config.minInliers = 2
        #expect(cft_create(&config) == nil)
        cft_destroy(nil)
    }

    @Test("Feature-selection hooks restrict and restore the original features")
    func selectionHooks() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Self.panel, corners: Self.panelCorners)
        let (status, result) = tracker.match(Self.liveFrame())
        #expect(status == CFT_STATUS_OK)

        var ids = [Int32](repeating: -1, count: Int(result.inlierCount))
        let count = cft_copy_inlier_feature_ids(tracker.handle, &ids, Int32(ids.count))
        #expect(count == result.inlierCount)
        #expect(ids.allSatisfy { $0 >= 0 && $0 < info.referenceFeatures })
        #expect(Set(ids).count == ids.count)

        #expect(cft_set_active_features(tracker.handle, ids, Int32(ids.count)) == CFT_STATUS_OK)
        #expect(cft_active_feature_count(tracker.handle) == Int32(ids.count))
        #expect(cft_copy_inlier_points(tracker.handle, nil, 0) == 0)

        let subset = tracker.match(Self.liveFrame())
        #expect(subset.0 == CFT_STATUS_OK)
        #expect(subset.1.referenceFeatures == Int32(ids.count))
        expectCorners(subset.1, near: Self.liveCorners, within: 3)

        let few = Array(ids.prefix(10))
        #expect(cft_set_active_features(tracker.handle, few, Int32(few.count)) == CFT_STATUS_INSUFFICIENT_FEATURES)
        let duplicated = Array(ids.prefix(39)) + [ids[0]]
        #expect(cft_set_active_features(tracker.handle, duplicated, 40) == CFT_STATUS_INVALID_ARGUMENT)
        let unknown = Array(ids.prefix(39)) + [info.referenceFeatures]
        #expect(cft_set_active_features(tracker.handle, unknown, 40) == CFT_STATUS_INVALID_ARGUMENT)
        #expect(cft_active_feature_count(tracker.handle) == Int32(ids.count))

        cft_restore_all_features(tracker.handle)
        #expect(cft_active_feature_count(tracker.handle) == info.referenceFeatures)
    }

    @Test("Every status and loss reason has a description")
    func descriptions() {
        for raw in 0...6 { #expect(String(cString: cft_status_description(CFTStatus(UInt32(raw)))) != "unknown status") }
        for raw in 0...8 {
            #expect(String(cString: cft_loss_reason_description(CFTLossReason(UInt32(raw)))) != "unknown loss reason")
        }
    }
}

// MARK: - Helpers

extension CFTStatus: @retroactive Error {}

private final class Tracker {
    let handle: OpaquePointer

    init() throws {
        guard let handle = cft_create(nil) else { throw CFT_STATUS_INTERNAL_ERROR }
        self.handle = handle
    }

    deinit { cft_destroy(handle) }

    @discardableResult
    func register(_ image: SyntheticGray, corners: [CFTPoint]) throws -> CFTRegistrationInfo {
        var info = CFTRegistrationInfo()
        let status = image.withImage { cft_register_reference(handle, $0, corners, &info) }
        guard status == CFT_STATUS_OK else { throw status }
        return info
    }

    func match(_ image: SyntheticGray) -> (CFTStatus, CFTMatchResult) {
        var result = CFTMatchResult()
        let status = image.withImage { cft_match_frame(handle, $0, &result) }
        return (status, result)
    }
}

private func corners(of result: CFTMatchResult) -> [CFTPoint] {
    [result.corners.0, result.corners.1, result.corners.2, result.corners.3]
}

private func expectCorners(_ result: CFTMatchResult, near truth: [CFTPoint], within tolerance: Float,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    for (found, expected) in zip(corners(of: result), truth) {
        let error = hypot(found.x - expected.x, found.y - expected.y)
        #expect(error <= tolerance, "corner \(found) is \(error) px from \(expected)", sourceLocation: sourceLocation)
    }
}

private func expectZeroCorners(_ result: CFTMatchResult, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(corners(of: result).allSatisfy { $0.x == 0 && $0.y == 0 }, sourceLocation: sourceLocation)
}

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

    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        let w = h[6] * x + h[7] * y + h[8]
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
