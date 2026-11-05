import ContourCore
import CoreVideo
import Foundation
import ImageIO
import Testing
import Tracking
@testable import ContourApp

/// The photo replay tool's controller, driven by scripted trackers so pairing,
/// ordering and stale-result handling are tested independently of accuracy.
@MainActor
@Suite("Tracking photo replay")
struct PhotoReplayControllerTests {

    @Test("Each tracker's result stays paired with the exact photo, in order")
    func pairing() async throws {
        let trackers = Trackers()
        trackers.script[.features] = { index in index == 1 ? .lost : .tracked(shift: 0.02) }
        let controller = PhotoReplayController(makeTracker: trackers.make)
        let photos = Self.photos(3)
        controller.setReference(try Self.reference())
        controller.setPhotos(photos)
        try await controller.waitUntilIdle()

        #expect(controller.laneStates == [.vision: .finished, .features: .finished])
        for (index, photo) in photos.enumerated() {
            let vision = try #require(controller.result(.vision, for: photo))
            #expect(vision.photoID == photo.id)
            #expect(vision.quad == Self.quad(index: index, shift: 0))
            let features = try #require(controller.result(.features, for: photo))
            #expect(features.quad == (index == 1 ? nil : Self.quad(index: index, shift: 0.02)))
            #expect(features.status == (index == 1 ? .lost(.notFound) : .tracked))
            #expect(vision.replayMilliseconds >= 0)
        }
        for tracker in trackers.all { #expect(await tracker.seen == photos.map(\.frame.timestamp)) }
        try await waitUntil { await trackers.allStopped() }
    }

    @Test("Separate tracker instances, each registered to the reference, with the current options")
    func separateTrackers() async throws {
        let trackers = Trackers()
        let controller = PhotoReplayController(makeTracker: trackers.make)
        let reference = try Self.reference()
        controller.setReference(reference)
        controller.setPhotos(Self.photos(2))
        try await controller.waitUntilIdle()
        #expect(trackers.all.count == 2)
        #expect(Set(trackers.created.map(\.lane)) == [.vision, .features])
        for tracker in trackers.all { #expect(await tracker.registeredPhotoID == reference.photo.id) }

        let options = FeatureTrackingOptions(excludeHighlights: false, normalizeContrast: true)
        controller.setOptions(options)
        try await controller.waitUntilIdle()
        #expect(trackers.created.suffix(2).allSatisfy { $0.options == options })
    }

    @Test("A registration failure is reported for that tracker only, with no outlines")
    func registrationFailure() async throws {
        let trackers = Trackers()
        trackers.failRegistration = [.vision]
        let controller = PhotoReplayController(makeTracker: trackers.make)
        let photos = Self.photos(2)
        controller.setReference(try Self.reference())
        controller.setPhotos(photos)
        try await controller.waitUntilIdle()

        guard case .failed(let message) = controller.laneStates[.vision] else {
            Issue.record("expected the Vision lane to fail")
            return
        }
        #expect(message.contains("couldn't lock onto the panel"))
        #expect(photos.allSatisfy { controller.result(.vision, for: $0) == nil })
        #expect(controller.laneStates[.features] == .finished)
        #expect(photos.allSatisfy { controller.result(.features, for: $0)?.quad != nil })
    }

    @Test("A tracker error on one photo is shown for that photo, without an outline")
    func trackError() async throws {
        let trackers = Trackers()
        trackers.script[.vision] = { index in index == 0 ? .fail : .tracked(shift: 0) }
        let controller = PhotoReplayController(makeTracker: trackers.make)
        let photos = Self.photos(2)
        controller.setReference(try Self.reference())
        controller.setPhotos(photos)
        try await controller.waitUntilIdle()
        let failed = try #require(controller.result(.vision, for: photos[0]))
        #expect(failed.quad == nil && failed.error != nil)
        #expect(controller.result(.vision, for: photos[1])?.quad == Self.quad(index: 1, shift: 0))
    }

    @Test("Changing options mid-replay discards delayed results and stops the old trackers")
    func optionsChangeDiscardsOldWork() async throws {
        try await expectStaleWorkDiscarded { controller in
            controller.setOptions(FeatureTrackingOptions(excludeHighlights: false))
        }
    }

    @Test("Replacing the reference mid-replay discards delayed results")
    func referenceChangeDiscardsOldWork() async throws {
        try await expectStaleWorkDiscarded { controller in
            controller.setReference(try Self.reference())
        }
    }

    @Test("Replacing the photos mid-replay discards delayed results")
    func photosChangeDiscardsOldWork() async throws {
        try await expectStaleWorkDiscarded { controller in
            controller.setPhotos(Self.photos(3))
        }
    }

    @Test("Replay is repeatable from the first photo")
    func repeatable() async throws {
        let trackers = Trackers()
        trackers.script[.features] = { index in index == 1 ? .lost : .tracked(shift: 0.01) }
        let controller = PhotoReplayController(makeTracker: trackers.make)
        let photos = Self.photos(3)
        controller.setReference(try Self.reference())
        controller.setPhotos(photos)
        try await controller.waitUntilIdle()
        let first = photos.map { (controller.result(.vision, for: $0)?.quad, controller.result(.features, for: $0)?.quad) }

        controller.selectedIndex = 2
        controller.replay()
        try await controller.waitUntilIdle()
        let second = photos.map { (controller.result(.vision, for: $0)?.quad, controller.result(.features, for: $0)?.quad) }
        #expect(first.map(\.0) == second.map(\.0))
        #expect(first.map(\.1) == second.map(\.1))
        #expect(trackers.all.count == 4)
        for tracker in trackers.all.suffix(2) { #expect(await tracker.seen == photos.map(\.frame.timestamp)) }
    }

    @Test("Reset clears inputs and results and stops running trackers")
    func reset() async throws {
        let trackers = Trackers()
        trackers.gated = true
        let controller = PhotoReplayController(makeTracker: trackers.make)
        controller.setReference(try Self.reference())
        controller.setPhotos(Self.photos(2))
        try await trackers.waitForBlockedTrack()

        controller.reset()
        #expect(controller.reference == nil && controller.photos.isEmpty && controller.results.isEmpty)
        await trackers.releaseAll()
        try await waitUntil { await trackers.allStopped() }
        #expect(controller.results.isEmpty)
        #expect(controller.laneStates == [.vision: .idle, .features: .idle])
    }

    // MARK: Loading

    @Test("Import failures are reported, not replayed")
    func importFailures() {
        #expect(throws: ReplayImageLoader.LoadError.unreadable("notes.txt")) {
            try ReplayImageLoader.frame(from: Data("not an image".utf8), name: "notes.txt", index: 0)
        }
        #expect(throws: ReplayImageLoader.LoadError.unreadable("empty")) {
            try ReplayImageLoader.referencePhoto(from: Data(), name: "empty")
        }
    }

    @Test("A photo stored rotated keeps its pixels and orientation as a camera frame")
    func orientationPreserved() async throws {
        let rotated = try #require(ReplayExample.testPhotos().last)
        let frame = try ReplayImageLoader.frame(from: rotated.data, name: rotated.name, index: 2)
        #expect(frame.orientation == .right)
        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 480)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == 640)
        let upright = try #require(await FrameImageRenderer().image(for: frame))
        #expect(upright.width == 640 && upright.height == 480)

        let reference = try ReplayImageLoader.referencePhoto(from: rotated.data, name: rotated.name)
        #expect(reference.orientation == .up)
        #expect(reference.pixelSize == PixelSize(width: 640, height: 480))
    }

    // MARK: Example with the real trackers

    @Test("The built-in example goes tracked → lost → recovered with the feature tracker")
    func exampleSequence() async throws {
        // Vision rectangle tracking crashes inside Vision itself on the iOS 27.1
        // simulator (EXC_BAD_ACCESS even on a plain rectangle), so the
        // simulator replays a stand-in for that lane. Devices run the real one.
        let controller = PhotoReplayController { lane, options in
            #if targetEnvironment(simulator)
            if lane == .vision { return ScriptedTracker(script: { _ in .lost }, failRegistration: false, gated: false) }
            #endif
            return PhotoReplayController.liveTracker(lane, options)
        }
        let example = ReplayExample.reference()
        let photo = try ReplayImageLoader.referencePhoto(from: example.data, name: example.name)
        controller.setReference(try ManualPanelReferenceBuilder.make(photo: photo, corners: ReplayExample.corners,
                                                                     layout: SurfaceMap(buttons: [], confidence: 1)))
        let photos = try ReplayExample.testPhotos().enumerated().map { index, photo in
            PhotoReplayController.Photo(name: photo.name,
                                        frame: try ReplayImageLoader.frame(from: photo.data, name: photo.name, index: index))
        }
        controller.setPhotos(photos)
        try await controller.waitUntilIdle(timeout: .seconds(30))

        let features = photos.map { controller.result(.features, for: $0) }
        #expect(features.map { $0?.status } == [.tracked, .lost(.notFound), .tracked])
        for index in [0, 2] {
            let quad = try #require(features[index]?.quad)
            let found = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            for (corner, expected) in zip(found, ReplayExample.liveCorners) {
                #expect(abs(corner.x - expected.x / 640) < 0.01 && abs(corner.y - expected.y / 480) < 0.01,
                        "photo \(index + 1): \(corner) vs \(expected)")
            }
        }
        #expect(features[1]?.quad == nil)
        // The Vision lane runs on the same photos; its accuracy isn't asserted here.
        #expect(photos.allSatisfy { controller.result(.vision, for: $0) != nil }
                || controller.laneStates[.vision].map { if case .failed = $0 { true } else { false } } == true)
    }

    // MARK: - Helpers

    /// Starts a replay, holds both trackers inside `track` for the first photo,
    /// applies `change`, then lets the old trackers finish.
    private func expectStaleWorkDiscarded(_ change: (PhotoReplayController) throws -> Void) async throws {
        let trackers = Trackers()
        trackers.gated = true
        let controller = PhotoReplayController(makeTracker: trackers.make)
        controller.setReference(try Self.reference())
        controller.setPhotos(Self.photos(2))
        try await trackers.waitForBlockedTrack()
        let old = trackers.all

        trackers.gated = false
        try change(controller)
        for tracker in old { await tracker.release() }
        try await controller.waitUntilIdle()

        try await waitUntil {
            for tracker in old where await !tracker.stopped { return false }
            return true
        }
        // Every result shown came from the new trackers, for the new photos.
        let newTrackers = trackers.all.filter { tracker in !old.contains { $0 === tracker } }
        #expect(newTrackers.count == 2)
        for photo in controller.photos {
            for lane in PhotoReplayController.Lane.allCases {
                let result = try #require(controller.result(lane, for: photo))
                #expect(result.photoID == photo.id)
            }
        }
        #expect(controller.results.values.allSatisfy { $0.count == controller.photos.count })
    }

    static func reference() throws -> PanelReference {
        let photo = PanelPhoto(data: Data([1]), pixelSize: PixelSize(width: 4, height: 3), orientation: .up,
                               timestamp: Date())
        return try ManualPanelReferenceBuilder.make(photo: photo, corners: [
            ImagePoint(x: 0.1, y: 0.1), ImagePoint(x: 0.9, y: 0.1), ImagePoint(x: 0.9, y: 0.9), ImagePoint(x: 0.1, y: 0.9),
        ], layout: SurfaceMap(buttons: [], confidence: 1))
    }

    static func photos(_ count: Int) -> [PhotoReplayController.Photo] {
        (0..<count).map { index in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA, nil, &buffer)
            return PhotoReplayController.Photo(name: "Photo \(index + 1)", frame: CameraFrame(
                pixelBuffer: buffer!, timestamp: Date(timeIntervalSinceReferenceDate: Double(index) + Double.random(in: 0..<0.5))))
        }
    }

    /// A distinct quad per photo index, so a mismatched pairing is visible.
    nonisolated static func quad(index: Int, shift: Double) -> PanelQuad {
        let d = 0.05 * Double(index) + shift
        return PanelQuad(topLeft: ImagePoint(x: 0.1 + d, y: 0.1), topRight: ImagePoint(x: 0.6 + d, y: 0.1),
                         bottomRight: ImagePoint(x: 0.6 + d, y: 0.6), bottomLeft: ImagePoint(x: 0.1 + d, y: 0.6))
    }
}

// MARK: - Scripted trackers

private enum Step { case tracked(shift: Double), lost, fail }
private struct ScriptFailure: Error {}

private actor ScriptedTracker: PanelTracking {
    let script: @Sendable (Int) -> Step
    let failRegistration: Bool
    private(set) var registeredPhotoID: UUID?
    private(set) var seen: [Date] = []
    private(set) var stopped = false
    private var gate: CheckedContinuation<Void, Never>?
    private var gated: Bool
    private(set) var blocked = false

    init(script: @escaping @Sendable (Int) -> Step, failRegistration: Bool, gated: Bool) {
        self.script = script
        self.failRegistration = failRegistration
        self.gated = gated
    }

    func startTracking(_ reference: PanelReference) throws {
        if failRegistration { throw PanelTrackingError.registrationFailed }
        registeredPhotoID = reference.photo.id
    }

    func track(_ frame: CameraFrame) async throws -> PanelObservation {
        let index = seen.count
        seen.append(frame.timestamp)
        if gated {
            blocked = true
            await withCheckedContinuation { gate = $0 }
            blocked = false
        }
        switch script(index) {
        case .tracked(let shift):
            return .tracked(PhotoReplayControllerTests.quad(index: index, shift: shift), confidence: 0.8, at: frame.timestamp)
        case .lost:
            return .lost(.notFound, at: frame.timestamp)
        case .fail:
            throw ScriptFailure()
        }
    }

    func stopTracking() { stopped = true }

    func release() {
        gated = false
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class Trackers {
    var script: [PhotoReplayController.Lane: @Sendable (Int) -> Step] = [:]
    var failRegistration: Set<PhotoReplayController.Lane> = []
    var gated = false
    private(set) var created: [(lane: PhotoReplayController.Lane, options: FeatureTrackingOptions, tracker: ScriptedTracker)] = []

    var all: [ScriptedTracker] { created.map(\.tracker) }

    func make(_ lane: PhotoReplayController.Lane, _ options: FeatureTrackingOptions) -> any PanelTracking {
        let tracker = ScriptedTracker(script: script[lane] ?? { _ in .tracked(shift: 0) },
                                      failRegistration: failRegistration.contains(lane), gated: gated)
        created.append((lane, options, tracker))
        return tracker
    }

    func waitForBlockedTrack() async throws {
        try await waitUntil {
            for tracker in self.all where await !tracker.blocked { return false }
            return !self.all.isEmpty
        }
    }

    func releaseAll() async { for tracker in all { await tracker.release() } }

    func allStopped() async -> Bool {
        for tracker in all where await !tracker.stopped { return false }
        return true
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

extension PhotoReplayController {
    func waitUntilIdle(timeout: Duration = .seconds(5)) async throws {
        try await waitUntil(timeout: timeout) { !self.isRunning }
    }
}
