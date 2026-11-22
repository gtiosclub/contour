//
//  ContourMocksTests.swift
//  ContourMocks
//
//  These tests exist to protect determinism. Every team builds against these
//  mocks until Week 4, so a mock that quietly starts returning different data
//  breaks four teams at once. If you change the canned microwave or the walk,
//  change these numbers deliberately and say so in the PR.
//

import ContourCore
import Foundation
import Testing
@testable import ContourMocks

@Suite("Canned surface map")
struct CannedSurfaceMapTests {

    @Test("the microwave has six buttons and stable ids")
    func microwaveShape() {
        let map = MockSurfaceMaps.microwave

        #expect(map.buttons.count == 6)
        #expect(map.confidence == 0.94)
        #expect(Set(map.buttons.map(\.id)).count == 6, "ids must be unique")
        #expect(map.buttons.allSatisfy { $0.label != nil })
    }

    @Test("buttons sit in two rows of three, y measured downward")
    func microwaveLayout() {
        let map = MockSurfaceMaps.microwave
        let topRow = map.buttons.filter { $0.bounds.minY < 0.5 }
        let bottomRow = map.buttons.filter { $0.bounds.minY >= 0.5 }

        #expect(topRow.count == 3)
        #expect(bottomRow.count == 3)
        #expect(map.button(labelled: "Popcorn")!.bounds.minY
                < map.button(labelled: "Start")!.bounds.minY,
                "Popcorn is ABOVE Start, so it has the smaller y — y grows downward")
    }

    @Test("no buttons overlap")
    func noOverlap() {
        let buttons = MockSurfaceMaps.microwave.buttons
        for a in buttons {
            for b in buttons where a.id != b.id {
                let separated = a.bounds.maxX <= b.bounds.minX
                    || b.bounds.maxX <= a.bounds.minX
                    || a.bounds.maxY <= b.bounds.minY
                    || b.bounds.maxY <= a.bounds.minY
                #expect(separated, "\(a.label ?? "?") overlaps \(b.label ?? "?")")
            }
        }
    }

    @Test("detection returns the canned map, and can be made to fail")
    func mockDetection() async throws {
        let photo = PanelPhoto(
            data: Data(),
            pixelSize: PixelSize(width: 4032, height: 3024),
            timestamp: MockTrackingSource.fixedEpoch
        )

        let working = MockSurfaceUnderstanding()
        let detection = try await working.detectPanel(from: photo)
        #expect(detection.map == MockSurfaceMaps.microwave)
        #expect(detection.referencePhotoID == photo.id)
        #expect(detection.quad == .fullFrame)
        #expect(try await working.detectPanel(from: photo) == detection)

        let broken = MockSurfaceUnderstanding(failure: .noPanelFound)
        await #expect(throws: SurfaceUnderstandingError.noPanelFound) {
            _ = try await broken.detectPanel(from: photo)
        }
    }
}

@Suite("Deterministic tracking walk")
struct MockTrackingSourceTests {

    @Test("the walk starts at start and lands exactly on target")
    func walkEndpoints() {
        let source = MockTrackingSource()

        #expect(source.frame(atStep: 0).fingertip == source.start)
        #expect(source.frame(atStep: source.steps).fingertip == source.target)
    }

    @Test("the same configuration produces byte-identical frames")
    func reproducible() async {
        let a = MockTrackingSource(steps: 4, interval: .milliseconds(1))
        let b = MockTrackingSource(steps: 4, interval: .milliseconds(1))

        var framesA: [TrackingFrame] = []
        for await frame in a.frames() { framesA.append(frame) }

        var framesB: [TrackingFrame] = []
        for await frame in b.frames() { framesB.append(frame) }

        #expect(framesA.count == 5)
        #expect(framesA == framesB, "mocks must be reproducible run to run")
    }

    @Test("seeded jitter is reproducible; a different seed differs")
    func seededJitter() {
        let a = MockTrackingSource(jitter: 0.01, seed: 42)
        let b = MockTrackingSource(jitter: 0.01, seed: 42)
        let c = MockTrackingSource(jitter: 0.01, seed: 43)

        #expect(a.frame(atStep: 7).fingertip == b.frame(atStep: 7).fingertip)
        #expect(a.frame(atStep: 7).fingertip != c.frame(atStep: 7).fingertip)
    }

    @Test("a scripted lost frame reports no fingertip")
    func scriptedDropout() {
        let source = MockTrackingSource(qualityOverrides: [3: .lost])
        let frame = source.frame(atStep: 3)

        #expect(frame.trackingQuality == .lost)
        #expect(frame.fingertip == nil)
    }

    @Test("timestamps advance by the interval from a fixed epoch")
    func deterministicTimestamps() {
        let source = MockTrackingSource(interval: .milliseconds(100))

        #expect(source.frame(atStep: 0).timestamp == MockTrackingSource.fixedEpoch)
        #expect(source.frame(atStep: 10).timestamp
                == MockTrackingSource.fixedEpoch.addingTimeInterval(1.0))
    }
}

@Suite("Placeholder guidance and printing feedback")
struct MockFeedbackTests {

    @Test("guidance points downward when the target is below the fingertip")
    func directionIsYDown() {
        let state = MockGuidance.state(
            fingertip: PanelPoint(x: 0.5, y: 0.2),
            target: PanelPoint(x: 0.5, y: 0.8),
            timestamp: MockTrackingSource.fixedEpoch
        )

        #expect(state.vector?.direction.dy ?? 0 > 0, "target below means +dy")
        #expect(PrintingFeedbackEngine.compass(state.vector!.direction) == "down")
    }

    @Test("arriving at the target raises exactly one outcome")
    func arrival() {
        let target = MockSurfaceMaps.microwaveStartButton
        let onIt = MockGuidance.state(
            for: TrackingFrame(
                timestamp: MockTrackingSource.fixedEpoch,
                fingertip: target.bounds.center,
                panel: MockTrackingSource().frame(atStep: 0).panel,
                trackingQuality: .good
            ),
            target: target
        )

        #expect(onIt.outcome == .arrived)
        #expect(onIt.isTerminal)
    }

    private func frame(at point: PanelPoint) -> TrackingFrame {
        TrackingFrame(
            timestamp: MockTrackingSource.fixedEpoch,
            fingertip: point,
            panel: MockTrackingSource().frame(atStep: 0).panel,
            trackingQuality: .good
        )
    }

    private func key(x: Double, y: Double, width: Double, height: Double) -> SurfaceMap.Button {
        SurfaceMap.Button(label: "key", bounds: PanelRect(x: x, y: y, width: width, height: height), confidence: 1)
    }

    /// Key sizes from hand-labelled microwave-01.jpg: digit, then a word button
    /// and its neighbours; then median and smallest digit keys off saved scans of
    /// the Magic Chef, with that map's median row and column spacing.
    @Test("a neighbour's center is outside the oval on real key sizes", arguments: [
        (0.2, 0.055, 0.295, 0.08),
        (0.27, 0.075, 0.305, 0.095),
        (0.2127, 0.0591, 0.212, 0.058),
        (0.0821, 0.0346, 0.212, 0.058),
    ])
    func neighbourIsOutside(width: Double, height: Double, columnStep: Double, rowStep: Double) {
        let target = key(x: 0.4, y: 0.5, width: width, height: height)
        let center = target.bounds.center
        for step in [PanelVector(dx: columnStep, dy: 0), PanelVector(dx: -columnStep, dy: 0),
                     PanelVector(dx: 0, dy: rowStep), PanelVector(dx: 0, dy: -rowStep)] {
            #expect(MockGuidance.state(for: frame(at: center.offset(by: step)), target: target).outcome == nil)
        }
        #expect(MockGuidance.state(for: frame(at: center), target: target).outcome == .arrived)
    }

    @Test("the oval is 45% of each side, on each axis separately")
    func ovalFollowsTheKey() {
        // The 0 key on hand-labelled microwave-01.jpg.
        let zero = key(x: 0.405, y: 0.835, width: 0.2, height: 0.065)
        let center = zero.bounds.center
        func arrived(_ dx: Double, _ dy: Double) -> Bool {
            MockGuidance.state(for: frame(at: center.offset(by: PanelVector(dx: dx, dy: dy))), target: zero)
                .outcome == .arrived
        }
        #expect(arrived(0.089, 0))
        #expect(!arrived(0.091, 0))
        #expect(arrived(0, 0.029))
        #expect(!arrived(0, 0.03))
        // Inside on each axis alone, but outside together: an oval, not a box.
        #expect(!arrived(0.08, 0.026))
    }

    @Test("a stop nearer the key below no longer counts as arrived")
    func oldCircleStopIsOut() {
        // The 8 and 0 keys on microwave-01 have centers 0.09 apart. This stop is
        // nearer the 0, and the old 0.05 circle called it arrived on the 8: the
        // real case behind typing 1, 3, 8 for 1, 3, 0.
        let eight = key(x: 0.405, y: 0.75, width: 0.2, height: 0.055)
        let stop = eight.bounds.center.offset(by: PanelVector(dx: 0, dy: 0.046))
        let oldCircle = MockGuidance.state(fingertip: stop, target: eight.bounds.center,
                                           timestamp: MockTrackingSource.fixedEpoch)
        #expect(oldCircle.outcome == .arrived)
        #expect(MockGuidance.state(for: frame(at: stop), target: eight).outcome == nil)
    }

    @Test("a thin word box gets the floor and a huge box gets the cap")
    func floorAndCap() {
        let thin = MockGuidance.arrivalZone(for: key(x: 0, y: 0, width: 0.01, height: 0.01))
        #expect(thin.x == 0.015 && thin.y == 0.015)
        let huge = MockGuidance.arrivalZone(for: key(x: 0, y: 0, width: 0.9, height: 0.5))
        #expect(huge.x == 0.12 && huge.y == 0.05)
    }

    @Test("off the oval, guidance still has a direction, and no fingertip has none")
    func directionOutsideOval() {
        let target = key(x: 0.4, y: 0.5, width: 0.2, height: 0.05)
        let center = target.bounds.center
        let beside = MockGuidance.state(for: frame(at: center.offset(by: PanelVector(dx: -0.3, dy: 0))), target: target)
        #expect(beside.vector?.direction.dx == 1)
        #expect(beside.outcome == nil)

        let lostFinger = TrackingFrame(timestamp: MockTrackingSource.fixedEpoch, fingertip: nil,
                                       panel: MockTrackingSource().frame(atStep: 0).panel, trackingQuality: .degraded)
        #expect(MockGuidance.state(for: lostFinger, target: target).vector == nil)
    }

    @Test("a lost frame becomes lostTracking")
    func lostBecomesOutcome() {
        let state = MockGuidance.state(
            for: .lost(at: MockTrackingSource.fixedEpoch),
            target: MockSurfaceMaps.microwaveStartButton
        )

        #expect(state.outcome == .lostTracking)
        #expect(state.vector == nil)
    }

    @Test("the printing engine records everything it is handed")
    func engineRecords() async {
        let engine = PrintingFeedbackEngine(isPrinting: false)
        let source = MockTrackingSource(steps: 3, interval: .milliseconds(1))
        let target = MockSurfaceMaps.microwaveStartButton

        for await frame in source.frames() {
            await engine.present(MockGuidance.state(for: frame, target: target))
        }

        let received = await engine.received
        #expect(received.count == 4)
        #expect(await engine.outcomes.last == .arrived, "the walk ends on the target")
    }
}
