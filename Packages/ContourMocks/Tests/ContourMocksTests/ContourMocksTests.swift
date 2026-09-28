import ContourCore
import Foundation
import Testing
@testable import ContourMocks

@Suite("Canned surface map")
struct CannedSurfaceMapTests {
    @Test("the microwave is a six-button 2x3 grid with an icon-only control")
    func microwaveShape() {
        let map = MockSurfaceMap.microwave

        #expect(map.buttons.count == 6)
        #expect(map.button(labelled: "Start")?.confidence == 0.94)
        #expect(map.button(labelled: "Stop")?.confidence == 0.91)
        #expect(map.button(labelled: "Popcorn")?.confidence == 0.72)
        #expect(map.buttons.contains(where: { $0.label == nil }))

        let topRow = map.buttons.filter { $0.bounds.center.y < 0.5 }
        let bottomRow = map.buttons.filter { $0.bounds.center.y >= 0.5 }
        #expect(topRow.count == 3)
        #expect(bottomRow.count == 3)
    }
}

@Suite("Deterministic tracking")
struct MockTrackingSourceTests {
    @Test("the same scripted run emits identical frames")
    func reproducible() async {
        let a = MockTrackingSource(run: .withDropout)
        let b = MockTrackingSource(run: .withDropout)

        var framesA: [TrackingFrame] = []
        for await frame in a.frames() { framesA.append(frame) }

        var framesB: [TrackingFrame] = []
        for await frame in b.frames() { framesB.append(frame) }

        #expect(framesA == framesB)
        #expect(framesA.contains(where: { $0.trackingQuality == .lost && $0.fingertip == nil }))
    }

    @Test("overshoot goes 0.1 panel units past the target before returning")
    func overshoot() {
        let source = MockTrackingSource(run: .overshoot)
        let point = source.frame(atStep: source.steps * 4 / 5).fingertip!
        let direction = source.run.start.vector(to: source.target).normalized!
        let beyondTarget = source.target.vector(to: point)
        let projection = beyondTarget.dx * direction.dx + beyondTarget.dy * direction.dy
        #expect(abs(projection - 0.1) < 0.000_001)
    }

    @Test("all presets arrive and hold on the selected target")
    func presetsArrive() {
        for run in [MockRun.straight, .overshoot, .withDropout] {
            let source = MockTrackingSource(run: run)
            #expect(source.frame(atStep: source.totalSteps).fingertip == source.target)
            #expect(source.frame(atStep: source.steps + 30).fingertip == source.target)
        }
    }
}

@Suite("Guidance math")
struct GuidanceMathTests {
    private let target = MockSurfaceMap.microwaveStartButton
    private let timestamp = MockTrackingSource.fixedEpoch

    @Test("center to center has no distance")
    func centerToCenter() {
        let frame = TrackingFrame(
            timestamp: timestamp,
            fingertip: target.bounds.center,
            panel: .unknown,
            trackingQuality: .good
        )

        let state = GuidanceMath.compute(frame: frame, target: target)
        #expect(state.vector?.normalizedDistance == 0)
        #expect(state.vector?.direction == .zero)
        #expect(state.outcome == .arrived)
    }

    @Test("opposite corners normalize to one")
    func oppositeCorners() {
        let cornerTarget = SurfaceMap.Button(
            label: "Corner",
            bounds: PanelRect(x: 1, y: 1, width: 0, height: 0),
            confidence: 1
        )
        let frame = TrackingFrame(
            timestamp: timestamp,
            fingertip: .origin,
            panel: .unknown,
            trackingQuality: .good
        )

        let state = GuidanceMath.compute(frame: frame, target: cornerTarget)
        #expect(state.vector?.normalizedDistance == 1)
    }

    @Test("missing fingertip produces lost tracking")
    func missingFingertip() {
        let state = GuidanceMath.compute(
            frame: .lost(at: timestamp),
            target: target
        )

        #expect(state.outcome == .lostTracking)
        #expect(state.vector == nil)
    }
}
