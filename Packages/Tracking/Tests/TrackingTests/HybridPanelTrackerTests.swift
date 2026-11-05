import ContourCore
import ContourFeatureMatcher
import CoreVideo
import Foundation
import Testing
@testable import Tracking

@Suite("Hybrid tracker coordinator")
struct HybridPanelTrackerTests {
    @Test("Only accepted views count; the final accepted view precedes selection")
    func acceptedViewsAndSelection() async throws {
        let visual = CoordinatorVisual()
        let tracker = HybridPanelTracker(visual: visual, makeAlignment: {
            CoordinatorPolicy(steps: [.init(accepted: true), .init(),
                .init(accepted: true, ready: true), .init(ready: true),
                .init(accepted: true, restore: true), .init(accepted: true, ready: true)])
        })
        try await tracker.startTracking(reference())
        var results: [PanelObservation] = []
        for _ in 0..<6 { results.append(try await tracker.track(frame())) }
        #expect(await visual.events == ["start", "track", "observe", "track",
            "track", "observe", "finish", "track", "track", "restore", "observe",
            "track", "observe", "finish"])
        #expect(results[0].hybridDiagnostics?.stableFeatures == nil)
        #expect(results[2].hybridDiagnostics?.stableFeatures == 47)
        #expect(results[3].hybridDiagnostics?.stableFeatures == 47)
        #expect(results[4].hybridDiagnostics?.stableFeatures == nil)
        #expect(results[5].hybridDiagnostics?.stableFeatures == 47)
    }

    @Test("A backend that keeps originals does not invent a selected count")
    func noSelection() async throws {
        let tracker = HybridPanelTracker(visual: CoordinatorVisual(selectedCount: nil), makeAlignment: {
            CoordinatorPolicy(steps: [.init(accepted: true, ready: true)])
        })
        try await tracker.startTracking(reference())
        #expect(try await tracker.track(frame()).hybridDiagnostics?.stableFeatures == nil)
    }

    @Test("Replacement waits for old backend hooks and rejects obsolete output",
          arguments: ["start", "track", "restore", "observe", "finish"])
    func replacementDuringHook(hook: String) async throws {
        let visual = CoordinatorVisual()
        let tracker = HybridPanelTracker(visual: visual, makeAlignment: {
            CoordinatorPolicy(steps: [.init(accepted: true, ready: true, restore: true)])
        })
        if hook != "start" { try await tracker.startTracking(reference()) }
        await visual.pause(at: hook)
        let old = Task {
            if hook == "start" { try await tracker.startTracking(reference()) }
            else { _ = try await tracker.track(frame()) }
        }
        await visual.waitForPause()
        let newer = try reference()
        let generation = await tracker.generation
        let replacement = Task { try await tracker.startTracking(newer) }
        // The new lifecycle request must be registered before releasing the old hook.
        await waitUntil { await tracker.generation != generation }
        #expect(await visual.referenceID != newer.photo.id)
        await visual.release()
        await #expect(throws: PanelTrackingError.superseded) { try await old.value }
        try await replacement.value
        #expect(await visual.referenceID == newer.photo.id)
        let output = try await tracker.track(frame())
        #expect(output.status == .tracked)
    }

    @Test("Stop drains an old hook, while overlapping frame processing is rejected")
    func stopAndOverlap() async throws {
        let visual = CoordinatorVisual()
        let tracker = HybridPanelTracker(visual: visual)
        try await tracker.startTracking(reference())
        await visual.pause(at: "track")
        let old = Task { try await tracker.track(frame()) }
        await visual.waitForPause()
        await #expect(throws: PanelTrackingError.frameInFlight) { try await tracker.track(frame()) }
        let generation = await tracker.generation
        let stopping = Task { await tracker.stopTracking() }
        await waitUntil { await tracker.generation != generation }
        await visual.release()
        await #expect(throws: PanelTrackingError.superseded) { try await old.value }
        await stopping.value
        #expect(await visual.referenceID == nil)
        #expect(try await tracker.track(frame()).quad == nil)
    }

    @Test("Caller cancellation cannot publish or reuse partially selected state",
          arguments: ["start", "track", "restore", "observe", "finish"])
    func cancelledHook(hook: String) async throws {
        let visual = CoordinatorVisual()
        let tracker = HybridPanelTracker(visual: visual, makeAlignment: {
            CoordinatorPolicy(steps: [.init(accepted: true, ready: true, restore: true)])
        })
        if hook != "start" { try await tracker.startTracking(reference()) }
        await visual.pause(at: hook)
        let work = Task {
            if hook == "start" { try await tracker.startTracking(reference()) }
            else { _ = try await tracker.track(frame()) }
        }
        await visual.waitForPause()
        work.cancel()
        await visual.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await tracker.track(frame()).quad == nil)
        try await tracker.startTracking(reference())
        #expect(try await tracker.track(frame()).status == .tracked)
    }

    @Test("Real feature tracking and geometry compose without world data")
    func realVisualFallback() async throws {
        let tracker = HybridPanelTracker()
        try await tracker.startTracking(FeaturePanelTrackerTests.reference())
        let frame = FeaturePanelTrackerTests.camera(FeatureMatcherBackendTests.liveFrame())
        let output = try await tracker.track(frame)
        #expect(output.status == .tracked)
        #expect(output.timestamp == frame.timestamp)
        #expect(output.featureDiagnostics?.inlierCount ?? 0 >= 20)
        #expect(output.hybridDiagnostics?.source == .visual)
        #expect(output.hybridDiagnostics?.calibrationReady == false)
    }

    @Test("Real matching calibrates from synchronized views and predicts through visual loss")
    func realCalibration() async throws {
        let tracker = HybridPanelTracker()
        try await tracker.startTracking(reference())
        let plane = HybridScene.surface(at: 0.5)
        let firstWorld = HybridScene.camera(at: .zero, planes: [plane])
        // Preserve the reference texture's 4:3 shape in the portrait image;
        // stretching it into a square would be testing ORB's distortion limits.
        let initialQuad = PanelQuad(topLeft: ImagePoint(x: 0.15, y: 0.303125),
            topRight: ImagePoint(x: 0.85, y: 0.303125), bottomRight: ImagePoint(x: 0.85, y: 0.696875),
            bottomLeft: ImagePoint(x: 0.15, y: 0.696875))
        let corners = try PanelWorldGeometry(snapshot: firstWorld)
            .corners(of: initialQuad, on: plane)
        var output: PanelObservation?
        for index in 0..<14 {
            let world = HybridScene.camera(at: HybridScene.sideways * (Float(index) - 6), planes: [plane])
            let truth = try PanelWorldGeometry(snapshot: world).quad(for: corners)
            var image = SyntheticGray.textured(width: 480, height: 640, seed: 99)
            let normalized: [ImagePoint] = [truth.topLeft, truth.topRight, truth.bottomRight, truth.bottomLeft]
            var points: [CFTPoint] = []
            for point in normalized {
                let x = Float(point.x * 480.0 - 0.5)
                let y = Float(point.y * 640.0 - 0.5)
                points.append(CFTPoint(x: x, y: y))
            }
            if index < 13 {
                image.warp(FeatureMatcherBackendTests.panel,
                    from: FeatureMatcherBackendTests.panelCorners, to: points)
            }
            let frame = CameraFrame(pixelBuffer: image.pixelBuffer(storedFor: .right),
                timestamp: HybridScene.start.addingTimeInterval(Double(index) * 0.15),
                orientation: .right, world: world)
            output = try await tracker.track(frame)
        }
        #expect(output?.status == .tracked)
        #expect(output?.hybridDiagnostics?.calibrationReady == true)
        #expect(output?.hybridDiagnostics?.source == .world)
        await tracker.stopTracking()
    }

    @Test("Stop serializes with every awaited visual hook", arguments: ["start", "restore", "observe", "finish"])
    func stopDuringHook(hook: String) async throws {
        let visual = CoordinatorVisual()
        let tracker = HybridPanelTracker(visual: visual, makeAlignment: {
            CoordinatorPolicy(steps: [.init(accepted: true, ready: true, restore: true)])
        })
        if hook != "start" { try await tracker.startTracking(reference()) }
        await visual.pause(at: hook)
        let old = Task {
            if hook == "start" { try await tracker.startTracking(reference()) }
            else { _ = try await tracker.track(frame()) }
        }
        await visual.waitForPause()
        let generation = await tracker.generation
        let stopping = Task { await tracker.stopTracking() }
        await waitUntil { await tracker.generation != generation }
        await visual.release()
        await #expect(throws: PanelTrackingError.superseded) { try await old.value }
        await stopping.value
        #expect(await visual.referenceID == nil)
    }

    private func frame() throws -> CameraFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        return CameraFrame(pixelBuffer: try #require(buffer), timestamp: Date())
    }
    private func reference() throws -> PanelReference { try FeaturePanelTrackerTests.reference() }
    private func waitUntil(_ predicate: () async -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < end { await Task.yield() }
        #expect(await predicate())
    }
}

private struct CoordinatorPolicy: PanelAlignmentPolicy {
    struct Step: Sendable {
        var accepted = false
        var ready = false
        var restore = false
    }
    var steps: [Step]
    var isCalibrated = false
    var acceptedCalibrationView = false
    var didReset = false
    var needsFeatureRestore = false
    mutating func update(visual: PanelObservation, world: WorldCameraSnapshot?) -> PanelObservation {
        let step = steps.isEmpty ? Step() : steps.removeFirst()
        isCalibrated = step.ready
        acceptedCalibrationView = step.accepted
        didReset = step.restore
        needsFeatureRestore = step.restore
        var result = visual
        result.hybridDiagnostics = HybridTrackingDiagnostics(mode: .visual, message: "Scripted",
            calibrationFrames: 1, calibrationReady: step.ready)
        return result
    }
}

private actor CoordinatorVisual: CalibratablePanelTracking {
    private(set) var events: [String] = []
    private(set) var referenceID: UUID?
    let selectedCount: Int?
    private var pausedHook: String?
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    init(selectedCount: Int? = 47) { self.selectedCount = selectedCount }
    func pause(at hook: String) { pausedHook = hook; entered = false }
    private func event(_ name: String) async {
        events.append(name)
        if pausedHook == name {
            pausedHook = nil; entered = true
            entry?.resume(); entry = nil
            await withCheckedContinuation { gate = $0 }
        }
    }
    func waitForPause() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { gate?.resume(); gate = nil }
    func startTracking(_ reference: PanelReference) async {
        await event("start")
        referenceID = reference.photo.id
    }
    func stopTracking() async { await event("stop"); referenceID = nil }
    func track(_ frame: CameraFrame) async -> PanelObservation {
        await event("track")
        return .tracked(.fullFrame, confidence: 0.9, at: frame.timestamp)
    }
    func observeCalibrationView() async { await event("observe") }
    func finishCalibration() async -> Int? { await event("finish"); return selectedCount }
    func resetCalibration() async { await event("restore") }
}
