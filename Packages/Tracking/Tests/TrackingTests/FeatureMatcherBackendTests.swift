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

    @Test("A valid view is tracked even when every homogeneous w is negative")
    func negativeDenominators() throws {
        // OpenCV normalizes h22 = 1, so w = 1 at the reference origin. With the
        // panel far from the origin and the horizon line between them, every
        // panel corner has w < 0, yet the view is ordinary and visible.
        let reference = SyntheticGray.textured(width: 3500, height: 400, seed: 7)
        let referenceCorners = [CFTPoint(x: 3000, y: 30), CFTPoint(x: 3400, y: 30),
                                CFTPoint(x: 3400, y: 330), CFTPoint(x: 3000, y: 330)]
        let truth = Homography(h: [-0.6875, 0, 1987.5, 0, -0.5, -30, -1.0 / 2000, 0, 1])
        let liveCorners = referenceCorners.map { corner in
            let (x, y) = truth.apply(Double(corner.x), Double(corner.y))
            return CFTPoint(x: Float(x), y: Float(y))
        }
        #expect(referenceCorners.allSatisfy { truth.w(Double($0.x), Double($0.y)) < 0 })
        #expect(liveCorners.allSatisfy { $0.x > 0 && $0.x < 640 && $0.y > 0 && $0.y < 480 })

        var frame = SyntheticGray.textured(width: 640, height: 480, seed: 99)
        frame.warp(reference, from: referenceCorners, to: liveCorners)
        let tracker = try Tracker()
        try tracker.register(reference, corners: referenceCorners)
        let (status, result) = tracker.match(frame)
        #expect(status == CFT_STATUS_OK, "\(String(cString: cft_loss_reason_description(result.lossReason)))")
        expectCorners(result, near: liveCorners, within: 3)
    }

    @Test("A failed replacement registration drops the previous reference and evidence")
    func failedReplacementUnregisters() throws {
        let tracker = try Tracker()
        try tracker.register(Self.panel, corners: Self.panelCorners)
        #expect(tracker.match(Self.liveFrame()).0 == CFT_STATUS_OK)
        #expect(cft_copy_inlier_points(tracker.handle, nil, 0) > 0)

        var info = CFTRegistrationInfo(referenceFeatures: 99)
        let status = Self.panel.withImage { cft_register_reference(tracker.handle, $0, nil, &info) }
        #expect(status == CFT_STATUS_INVALID_ARGUMENT)
        #expect(info.referenceFeatures == 0)
        #expect(cft_reference_feature_count(tracker.handle) == 0)
        #expect(cft_copy_inlier_points(tracker.handle, nil, 0) == 0)
        #expect(cft_copy_inlier_feature_ids(tracker.handle, nil, 0) == 0)
        #expect(tracker.match(Self.liveFrame()).0 == CFT_STATUS_NOT_REGISTERED)

        // Every other failure path behaves the same way.
        try tracker.register(Self.panel, corners: Self.panelCorners)
        #expect(throws: CFT_STATUS_INSUFFICIENT_FEATURES) {
            try tracker.register(SyntheticGray(width: 480, height: 360, value: 90), corners: Self.panelCorners)
        }
        #expect(tracker.match(Self.liveFrame()).0 == CFT_STATUS_NOT_REGISTERED)
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
