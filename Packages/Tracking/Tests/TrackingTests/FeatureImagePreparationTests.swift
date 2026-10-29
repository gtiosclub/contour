import ContourFeatureMatcher
import Foundation
import Testing

/// Clipped-highlight exclusion and optional contrast enhancement (#83), run on
/// the reference and every frame before feature extraction.
@Suite("Feature image preparation")
struct FeatureImagePreparationTests {
    typealias Fixture = FeatureMatcherBackendTests

    @Test("Clipped hotspots are excluded and reported; no kept feature's support touches them")
    func clippedPatch() throws {
        let tracker = try Tracker()
        try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        let clean = tracker.match(Fixture.liveFrame())
        let (status, glared) = tracker.match(Fixture.liveFrame().withGlare())
        #expect(status == CFT_STATUS_OK)

        // Rectangle 90×70 plus a radius-30 disc (2,821 px when rasterized here).
        let glareFraction = Float(90 * 70 + Self.discPixels(radius: 30)) / Float(640 * 480)
        #expect(abs(glared.excludedHighlightFraction - clean.1.excludedHighlightFraction - glareFraction) < 0.001)
        #expect(glared.saturatedFraction > glared.excludedHighlightFraction)
        #expect(glared.excludedFeatures > clean.1.excludedFeatures)

        // A level-0 ORB descriptor reaches ~23 px from its center (radius 0.75 × 31).
        var points = [CFTPoint](repeating: CFTPoint(), count: Int(glared.inlierCount))
        cft_copy_inlier_points(tracker.handle, &points, Int32(points.count))
        #expect(points.allSatisfy { SyntheticGray.distanceToGlare($0) > 23 })
    }

    @Test("Disabled filtering keeps every feature but still reports saturation")
    func disabledFiltering() throws {
        let on = try Tracker()
        let off = try Tracker { $0.excludeHighlights = 0 }
        try on.register(Fixture.panel, corners: Fixture.panelCorners)
        let registration = try off.register(Fixture.panel, corners: Fixture.panelCorners)
        #expect(registration.excludedFeatures == 0)
        #expect(registration.excludedHighlightFraction == 0)

        let frame = Fixture.liveFrame().withGlare()
        let (onStatus, filtered) = on.match(frame)
        let (offStatus, unfiltered) = off.match(frame)
        #expect(onStatus == CFT_STATUS_OK && offStatus == CFT_STATUS_OK)
        #expect(unfiltered.excludedHighlightFraction == 0)
        #expect(unfiltered.excludedFeatures == 0)
        #expect(unfiltered.saturatedFraction == filtered.saturatedFraction)
        #expect(unfiltered.frameFeatures > filtered.frameFeatures)
    }

    @Test("Only substantial compact hotspots qualify: not lettering, rings, or a white surface")
    func whichRegionsQualify() throws {
        let tracker = try Tracker()
        try tracker.register(Fixture.panel, corners: Fixture.panelCorners)

        var image = SyntheticGray(width: 640, height: 480, value: 100)
        image.fill((0, 0, 640, 140), value: 255)             // white surface, 29% of the image
        image.fill((40, 200, 40, 40), value: 255)            // hotspot, 1,600 px
        image.disc(cx: 160, cy: 220, r: 20, value: 255)      // round hotspot
        for i in 0..<6 { image.fill((240 + i * 12, 200, 6, 10), value: 255) }  // lettering, 60 px each
        image.fill((360, 200, 60, 60), value: 255)           // ring: compact outline, hollow
        image.fill((370, 210, 40, 40), value: 100)
        image.fill((460, 200, 30, 30), value: 249)           // bright but not clipped

        let (status, result) = tracker.match(image)
        #expect(status == CFT_STATUS_LOST)
        let total = Float(640 * 480)
        let saturated = Float(640 * 140 + 1600 + Self.discPixels(radius: 20) + 6 * 60 + (3600 - 1600))
        #expect(abs(result.saturatedFraction - saturated / total) < 0.0005)
        #expect(abs(result.excludedHighlightFraction - Float(1600 + Self.discPixels(radius: 20)) / total) < 0.0005)
    }

    @Test("Contrast enhancement never changes what counts as clipped")
    func glareJudgedBeforeContrast() throws {
        let plain = try Tracker()
        let enhanced = try Tracker { $0.normalizeContrast = 1 }
        try plain.register(Fixture.panel, corners: Fixture.panelCorners)
        try enhanced.register(Fixture.panel, corners: Fixture.panelCorners)
        let frame = Fixture.liveFrame().withGlare()
        let a = plain.match(frame).1, b = enhanced.match(frame).1
        #expect(a.saturatedFraction == b.saturatedFraction)
        #expect(a.excludedHighlightFraction == b.excludedHighlightFraction)
    }

    @Test("A dim, low-contrast scene fails honestly without enhancement and tracks with it")
    func lowContrast() throws {
        let reference = Fixture.panel.dimmed(range: 20)
        let frame = Fixture.liveFrame().dimmed(range: 20)

        let plain = try Tracker()
        #expect(throws: CFT_STATUS_INSUFFICIENT_FEATURES) {
            try plain.register(reference, corners: Fixture.panelCorners)
        }

        let enhanced = try Tracker { $0.normalizeContrast = 1 }
        try enhanced.register(reference, corners: Fixture.panelCorners)
        let (status, result) = enhanced.match(frame)
        #expect(status == CFT_STATUS_OK)
        expectCorners(result, near: Fixture.liveCorners, within: 3)
    }

    @Test("A washed-out panel is reported as lost with its saturation, not tracked or excluded away")
    func washout() throws {
        let tracker = try Tracker()
        try tracker.register(Fixture.panel, corners: Fixture.panelCorners)
        var frame = Fixture.liveFrame()
        frame.fill((120, 80, 400, 330), value: 255)
        let (status, result) = tracker.match(frame)
        #expect(status == CFT_STATUS_LOST)
        #expect(result.saturatedFraction > 0.4)
        // Too large to be a hotspot: the matcher fails on missing texture instead.
        #expect(result.excludedHighlightFraction < 0.01)
        #expect(result.confidence == 0)
    }

    @Test("Glare in the reference is excluded at registration and reported")
    func referenceGlare() throws {
        let tracker = try Tracker()
        let glared = Fixture.panel.withGlare()
        let info = try tracker.register(glared, corners: Fixture.panelCorners)
        let clean = try Tracker().register(Fixture.panel, corners: Fixture.panelCorners)
        #expect(info.excludedFeatures > clean.excludedFeatures)
        #expect(info.excludedHighlightFraction > clean.excludedHighlightFraction)
        #expect(info.saturatedFraction > clean.saturatedFraction)
        #expect(tracker.match(Fixture.liveFrame()).0 == CFT_STATUS_OK)
    }

    @Test("Invalid preparation settings are refused")
    func invalidConfig() {
        var config = CFTConfig()
        cft_default_config(&config)
        config.saturationThreshold = 0
        #expect(cft_create(&config) == nil)
        cft_default_config(&config)
        config.minHighlightFill = 1.5
        #expect(cft_create(&config) == nil)
        cft_default_config(&config)
        config.claheGridSize = 0
        #expect(cft_create(&config) == nil)
    }

    static func discPixels(radius r: Int) -> Int {
        var count = 0
        for y in -r...r { for x in -r...r where x * x + y * y <= r * r { count += 1 } }
        return count
    }
}
