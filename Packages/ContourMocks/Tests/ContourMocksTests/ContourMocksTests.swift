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
        #expect(try await working.surfaceMap(from: photo) == MockSurfaceMaps.microwave)

        let broken = MockSurfaceUnderstanding(failure: .noPanelFound)
        await #expect(throws: SurfaceUnderstandingError.noPanelFound) {
            _ = try await broken.surfaceMap(from: photo)
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
