import ContourFeatureMatcher
import Foundation
import Testing

/// Persistent-feature selection across accepted calibration views (#84). No
/// world calibration needed: the test decides which views are accepted.
@Suite("Persistent feature selection")
struct FeatureSelectionTests {
    typealias Fixture = FeatureMatcherBackendTests

    @Test("Features hidden in most views are dropped; persistent ones spread across the panel are kept")
    func persistentAndTransient() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        // Left region hidden in 5 of 8 accepted views: present in only 3/8 < 60%.
        try observe(tracker, views: (0..<8).map { Fixture.calibrationView($0, hideTransient: $0 < 5) })
        #expect(cft_calibration_view_count(tracker.handle) == 8)

        let selected = cft_finish_calibration(tracker.handle)
        #expect(selected >= 40)
        #expect(selected < info.referenceFeatures)
        #expect(cft_active_feature_count(tracker.handle) == selected)
        #expect(cft_reference_feature_count(tracker.handle) == info.referenceFeatures)

        let active = activePoints(tracker)
        #expect(active.count == Int(selected))
        let hiddenEdge = Float(Fixture.transientRegion.0 + Fixture.transientRegion.2)
        #expect(active.allSatisfy { $0.x >= hiddenEdge - 1 })
        // Still spread over the visible panel, not one cluster.
        #expect(active.contains { $0.y < 100 } && active.contains { $0.y > 260 })
        #expect(active.contains { $0.x < 260 } && active.contains { $0.x > 380 })
    }

    @Test("The selected subset tracks accurately; descriptors and identities are unchanged")
    func subsetTracking() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        let before = referencePoints(tracker)
        // A small patch hidden in 5 of 8 views, like a reflection that moves.
        let patch = Fixture.transientPatch
        try observe(tracker, views: (0..<8).map { Fixture.calibrationView($0, hiding: $0 < 5 ? [patch] : []) })
        let selected = cft_finish_calibration(tracker.handle)
        #expect(selected >= 40 && selected < info.referenceFeatures)
        let inside = activePoints(tracker).filter {
            $0.x > Float(patch.0) && $0.x < Float(patch.0 + patch.2) && $0.y > Float(patch.1) && $0.y < Float(patch.1 + patch.3)
        }
        #expect(inside.isEmpty)

        let (status, result) = tracker.match(Fixture.liveFrame())
        #expect(status == CFT_STATUS_OK)
        #expect(result.referenceFeatures == selected)
        expectCorners(result, near: Fixture.liveCorners, within: 3)
        let covered = tracker.match(Fixture.liveFrame(cover: [(100, 60, 170, 130), (290, 220, 70, 60)]))
        #expect(covered.0 == CFT_STATUS_OK)
        expectCorners(covered.1, near: Fixture.liveCorners, within: 3)

        // Matching still uses the original descriptors and identities.
        let ids = inlierIDs(tracker)
        let active = Set(activeIDs(tracker))
        #expect(!ids.isEmpty && ids.allSatisfy { active.contains($0) })
        #expect(referencePoints(tracker) == before)
        #expect(cft_reference_feature_count(tracker.handle) == info.referenceFeatures)
    }

    @Test("Processed but unaccepted frames never train selection")
    func unacceptedViewsDoNotCount() throws {
        let tracker = try Tracker()
        try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        for index in 0..<10 {
            #expect(tracker.match(Fixture.calibrationView(index, hideTransient: false)).0 == CFT_STATUS_OK)
        }
        #expect(cft_calibration_view_count(tracker.handle) == 0)
        #expect(cft_finish_calibration(tracker.handle) == -1)

        // A lost frame can't be accepted, and one match counts once however often it's observed.
        #expect(tracker.match(SyntheticGray.textured(width: 640, height: 480, seed: 11)).0 == CFT_STATUS_LOST)
        #expect(cft_observe_calibration_view(tracker.handle) == CFT_STATUS_LOST)
        #expect(tracker.match(Fixture.liveFrame()).0 == CFT_STATUS_OK)
        #expect(cft_observe_calibration_view(tracker.handle) == CFT_STATUS_OK)
        #expect(cft_observe_calibration_view(tracker.handle) == CFT_STATUS_OK)
        #expect(cft_calibration_view_count(tracker.handle) == 1)
        // An error frame clears the last match, so it can't be observed afterwards.
        #expect(tracker.match(SyntheticGray(width: 8, height: 8)).0 == CFT_STATUS_INVALID_BUFFER)
        #expect(cft_observe_calibration_view(tracker.handle) == CFT_STATUS_LOST)
        #expect(cft_calibration_view_count(tracker.handle) == 1)
    }

    @Test("Exact persistence boundaries need exactly that share of views",
          arguments: [(Float(0.6), 10, 6), (0.6, 15, 9), (0.6, 5, 3), (0.6, 20, 12), (0.6, 25, 15),
                      (0.6, 8, 5), (0.6, 11, 7), (0.7, 10, 7), (0.3, 10, 3), (0.1, 30, 3),
                      (0.15, 20, 3), (0.35, 20, 7), (1.0, 7, 7), (0.0, 9, 1)])
    func persistenceBoundaries(_ persistence: Float, _ views: Int32, _ expected: Int32) {
        var config = CFTConfig()
        cft_default_config(&config)
        config.minPersistence = persistence
        config.minAppearances = 1
        #expect(cft_required_appearances(&config, views) == expected)
    }

    @Test("The appearance floor still applies", arguments: [(Int32(5), Int32(4)), (8, 5), (10, 6)])
    func appearanceFloor(_ views: Int32, _ expected: Int32) {
        var config = CFTConfig()
        cft_default_config(&config)  // 60%, at least 4 appearances
        #expect(cft_required_appearances(&config, views) == expected)
    }

    @Test("Features seen in exactly 60% of views qualify (6 of 10, 9 of 15)",
          arguments: [(10, 4), (15, 6)])
    func exactSixtyPercentQualifies(_ views: Int, _ hiddenIn: Int) throws {
        // The patch is hidden in `hiddenIn` views, so its features can appear in
        // at most 60% of them. Before the rounding fix, none could qualify.
        let patch = Fixture.transientPatch
        let tracker = try Tracker()
        try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(tracker, views: (0..<views).map {
            Fixture.calibrationView($0, hiding: $0 < hiddenIn ? [patch] : [])
        })
        #expect(cft_finish_calibration(tracker.handle) > 0)
        let inside = activePoints(tracker).filter {
            $0.x > Float(patch.0) && $0.x < Float(patch.0 + patch.2) && $0.y > Float(patch.1) && $0.y < Float(patch.1 + patch.3)
        }
        #expect(!inside.isEmpty)
    }

    @Test("Too few views keeps the original set")
    func tooFewViews() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(tracker, views: (0..<7).map { Fixture.calibrationView($0, hideTransient: false) })
        #expect(cft_finish_calibration(tracker.handle) == -1)
        #expect(cft_active_feature_count(tracker.handle) == info.referenceFeatures)
    }

    @Test("Inadequate count or coverage keeps the original set")
    func inadequateSelection() throws {
        let views = (0..<8).map { Fixture.calibrationView($0, hideTransient: $0 < 5) }

        let tooFew = try Tracker { $0.minSelectedFeatures = 5000 }
        let all = try tooFew.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(tooFew, views: views)
        #expect(cft_finish_calibration(tooFew.handle) == -1)
        #expect(cft_active_feature_count(tooFew.handle) == all.referenceFeatures)

        // The persistent features cover ~65% of the panel; demand more.
        let narrow = try Tracker { $0.minSelectedCoverage = 0.8 }
        try narrow.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(narrow, views: views)
        #expect(cft_finish_calibration(narrow.handle) == -1)
        #expect(cft_active_feature_count(narrow.handle) == all.referenceFeatures)
    }

    @Test("A small persistent cluster is rejected by the coverage guard at default settings")
    func clusterRejected() throws {
        // Every view hides two of the panel's four quadrants, except a small
        // central patch (6.7% of the panel) that is always visible. Each
        // quadrant is visible in 4 of 8 views (< 60%), so only the patch persists.
        let quadrants = [(40, 30, 200, 150), (240, 30, 200, 150), (240, 180, 200, 150), (40, 180, 200, 150)]
        let center = (190, 140, 100, 80)
        let pairs = [(0, 1), (2, 3), (0, 3), (1, 2), (0, 1), (2, 3), (0, 3), (1, 2)]
        let views = pairs.enumerated().map { index, pair in
            Fixture.calibrationView(index, hiding: [quadrants[pair.0], quadrants[pair.1]], keep: center)
        }

        let tracker = try Tracker()
        let info = try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(tracker, views: views)
        #expect(cft_finish_calibration(tracker.handle) == -1)
        #expect(cft_active_feature_count(tracker.handle) == info.referenceFeatures)

        // With the count floor lowered so it can't decide, coverage alone rejects
        // the cluster; with coverage disabled too, the cluster is what's selected.
        let coverageOnly = try Tracker { $0.minReferenceFeatures = 10; $0.minSelectedFeatures = 10 }
        try coverageOnly.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(coverageOnly, views: views)
        #expect(cft_finish_calibration(coverageOnly.handle) == -1)

        let unguarded = try Tracker {
            $0.minReferenceFeatures = 10; $0.minSelectedFeatures = 10; $0.minSelectedCoverage = 0
        }
        try unguarded.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(unguarded, views: views)
        #expect(cft_finish_calibration(unguarded.handle) >= 10)
        // Features centered within one descriptor radius of the always-visible patch.
        #expect(activePoints(unguarded).allSatisfy {
            $0.x >= Float(center.0) - 24 && $0.x <= Float(center.0 + center.2) + 24
                && $0.y >= Float(center.1) - 24 && $0.y <= Float(center.1 + center.3) + 24
        })
    }

    @Test("Reset restores every original feature and clears the counts")
    func resetRestores() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(tracker, views: (0..<8).map { Fixture.calibrationView($0, hideTransient: $0 < 5) })
        #expect(cft_finish_calibration(tracker.handle) > 0)

        cft_reset_calibration(tracker.handle)
        #expect(cft_active_feature_count(tracker.handle) == info.referenceFeatures)
        #expect(cft_calibration_view_count(tracker.handle) == 0)
        #expect(cft_finish_calibration(tracker.handle) == -1)
        #expect(tracker.match(Fixture.liveFrame()).1.referenceFeatures == info.referenceFeatures)

        // Calibration can be attempted again after a reset.
        try observe(tracker, views: (0..<8).map { Fixture.calibrationView($0, hideTransient: $0 < 5) })
        #expect(cft_finish_calibration(tracker.handle) > 0)
    }

    @Test("Registering a new reference discards the old selection state")
    func replacementDiscards() throws {
        let tracker = try Tracker()
        let info = try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        try observe(tracker, views: (0..<8).map { Fixture.calibrationView($0, hideTransient: $0 < 5) })
        #expect(cft_finish_calibration(tracker.handle) > 0)

        try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        #expect(cft_calibration_view_count(tracker.handle) == 0)
        #expect(cft_active_feature_count(tracker.handle) == info.referenceFeatures)
        cft_reset(tracker.handle)
        #expect(cft_calibration_view_count(tracker.handle) == 0)
        #expect(cft_finish_calibration(tracker.handle) == -1)
    }

    // MARK: - Helpers

    private func observe(_ tracker: Tracker, views: [SyntheticGray],
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        for view in views {
            let (status, _) = tracker.match(view)
            try #require(status == CFT_STATUS_OK, sourceLocation: sourceLocation)
            #expect(cft_observe_calibration_view(tracker.handle) == CFT_STATUS_OK, sourceLocation: sourceLocation)
        }
    }

    private func activeIDs(_ tracker: Tracker) -> [Int32] {
        var ids = [Int32](repeating: 0, count: Int(cft_copy_active_feature_ids(tracker.handle, nil, 0)))
        cft_copy_active_feature_ids(tracker.handle, &ids, Int32(ids.count))
        return ids
    }

    private func inlierIDs(_ tracker: Tracker) -> [Int32] {
        var ids = [Int32](repeating: 0, count: Int(cft_copy_inlier_feature_ids(tracker.handle, nil, 0)))
        cft_copy_inlier_feature_ids(tracker.handle, &ids, Int32(ids.count))
        return ids
    }

    private func referencePoints(_ tracker: Tracker) -> [CFTPoint] {
        var points = [CFTPoint](repeating: CFTPoint(), count: Int(cft_copy_reference_feature_points(tracker.handle, nil, 0)))
        cft_copy_reference_feature_points(tracker.handle, &points, Int32(points.count))
        return points
    }

    private func activePoints(_ tracker: Tracker) -> [CFTPoint] {
        let points = referencePoints(tracker)
        return activeIDs(tracker).map { points[Int($0)] }
    }
}

extension CFTPoint: @retroactive Equatable {
    public static func == (a: CFTPoint, b: CFTPoint) -> Bool { a.x == b.x && a.y == b.y }
}
