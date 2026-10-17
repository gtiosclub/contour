//
//  Issue12MocksTests.swift
//  ContourMocks
//
//  Issue #12: the keypad map, GuidanceMath, MockRun-driven tracking and the
//  chained guidance stream. As with the rest of this target, the point is to
//  pin determinism: if a number here changes, it changes every consumer's
//  fixtures, so change it on purpose.
//

import ContourCore
import Foundation
import Testing
@testable import ContourMocks

private typealias Key = MockSurfaceMaps.KeypadButton

@Suite("Issue #12 keypad map")
struct KeypadMapTests {

    @Test("six buttons: Start, Stop, Popcorn, +30s, Defrost and an icon-only Cancel")
    func shape() {
        let map = MockSurfaceMaps.microwaveKeypad

        #expect(map.buttons.count == 6)
        #expect(Set(map.buttons.map(\.id)).count == 6)
        #expect(Set(map.buttons.compactMap(\.label)) == ["Start", "Stop", "Popcorn", "+30s", "Defrost"])
        #expect(map.buttons.filter { $0.label == nil }.map(\.id) == [Key.cancel.id])
        #expect(map.buttons.allSatisfy { $0.bounds.center.isOnPanel })
    }

    @Test("confidences are uneven and pinned")
    func confidences() {
        #expect(MockSurfaceMaps.keypadButton(.start).confidence == 0.94)
        #expect(MockSurfaceMaps.keypadButton(.stop).confidence == 0.91)
        #expect(MockSurfaceMaps.keypadButton(.popcorn).confidence == 0.72)
        for key in [Key.addThirtySeconds, .defrost, .cancel] {
            #expect((0.80...0.95).contains(MockSurfaceMaps.keypadButton(key).confidence))
        }
    }

    @Test("a 2x3 grid with no overlaps, y measured downward")
    func grid() {
        let buttons = MockSurfaceMaps.microwaveKeypad.buttons
        #expect(Set(buttons.map(\.bounds.minY)).count == 2)
        #expect(Set(buttons.map(\.bounds.minX)).count == 3)
        #expect(MockSurfaceMaps.keypadButton(.popcorn).bounds.maxY
                < MockSurfaceMaps.keypadButton(.start).bounds.minY,
                "Popcorn is on the top row, so it has the smaller y")
        for a in buttons {
            for b in buttons where a.id != b.id {
                let separated = a.bounds.maxX <= b.bounds.minX || b.bounds.maxX <= a.bounds.minX
                    || a.bounds.maxY <= b.bounds.minY || b.bounds.maxY <= a.bounds.minY
                #expect(separated)
            }
        }
    }

    @Test("the keypad is additive: the original microwave is unchanged")
    func originalMicrowaveUntouched() {
        let original = MockSurfaceMaps.microwave
        #expect(original.buttons.allSatisfy { $0.label != nil })
        #expect(original.button(labelled: "Defrost")?.confidence == 0.61)
        #expect(Set(original.buttons.map(\.id)).isDisjoint(with: Key.allCases.map(\.id)))
        #expect(MockSurfaceUnderstanding().map == original)
    }
}

@Suite("GuidanceMath")
struct GuidanceMathTests {

    private func button(at point: PanelPoint) -> SurfaceMap.Button {
        SurfaceMap.Button(
            id: Key.start.id,
            label: "Target",
            bounds: PanelRect(x: point.x, y: point.y, width: 0, height: 0),
            confidence: 1
        )
    }

    private func frame(_ fingertip: PanelPoint?, quality: TrackingQuality = .good) -> TrackingFrame {
        TrackingFrame(
            timestamp: MockTrackingSource.fixedEpoch,
            fingertip: fingertip,
            panel: MockTrackingSource().frame(atStep: 0).panel,
            trackingQuality: quality
        )
    }

    @Test("centre to centre is distance 0")
    func centreToCentre() {
        let start = MockSurfaceMaps.keypadButton(.start)
        for radius in [0, GuidanceMath.defaultArrivalRadius] {
            let state = GuidanceMath.compute(frame: frame(start.bounds.center), target: start,
                                             arrivalRadius: radius)
            #expect(state.vector?.normalizedDistance == 0)
            #expect(state.outcome == .arrived)
        }
    }

    @Test("opposite corners are distance 1")
    func oppositeCorners() {
        let state = GuidanceMath.compute(frame: frame(.origin), target: button(at: PanelPoint(x: 1, y: 1)))
        #expect(state.vector?.normalizedDistance == 1)
        #expect(state.outcome == nil)
    }

    @Test("distance is clamped to 0...1 off the panel")
    func clamped() {
        let far = frame(PanelPoint(x: -1, y: -1))
        let target = button(at: PanelPoint(x: 1, y: 1))
        #expect(GuidanceMath.compute(frame: far, target: target).vector?.normalizedDistance == 1)

        // MockGuidance keeps its historical, unclamped distance.
        let legacy = MockGuidance.state(for: far, target: target)
        #expect((legacy.vector?.normalizedDistance ?? 0) > 1)
    }

    @Test("a nil fingertip, or lost quality, is lostTracking")
    func lost() {
        let target = MockSurfaceMaps.keypadButton(.start)
        for f in [frame(nil), frame(.center, quality: .lost), .lost(at: MockTrackingSource.fixedEpoch)] {
            let state = GuidanceMath.compute(frame: f, target: target)
            #expect(state.outcome == .lostTracking)
            #expect(state.vector == nil)
            #expect(state.timestamp == MockTrackingSource.fixedEpoch)
        }
    }

    @Test("a target below the fingertip is +dy (y grows downward)")
    func yDown() {
        let state = GuidanceMath.compute(frame: frame(PanelPoint(x: 0.5, y: 0.2)),
                                         target: button(at: PanelPoint(x: 0.5, y: 0.8)))
        #expect(state.vector?.direction == PanelVector(dx: 0, dy: 1))
        #expect(PrintingFeedbackEngine.compass(state.vector!.direction) == "down")
    }

    @Test("MockGuidance's fingertip geometry is GuidanceMath's, unclamped")
    func mockGuidanceDelegates() {
        let target = PanelPoint(x: 0.5, y: 0.62)
        for x in stride(from: -0.5, through: 1.5, by: 0.25) {
            for y in stride(from: -0.5, through: 1.5, by: 0.25) {
                let tip = PanelPoint(x: x, y: y)
                let legacy = MockGuidance.state(fingertip: tip, target: target,
                                                timestamp: MockTrackingSource.fixedEpoch)
                let shared = GuidanceMath.state(from: tip, to: target,
                                                timestamp: MockTrackingSource.fixedEpoch,
                                                clampsDistance: false)
                #expect(legacy == shared)
                if let vector = legacy.vector, legacy.outcome == nil {
                    #expect(vector.normalizedDistance == tip.distance(to: target) / 2.0.squareRoot())
                }
            }
        }
    }
}
