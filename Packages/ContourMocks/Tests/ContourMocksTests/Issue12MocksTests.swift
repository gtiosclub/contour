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

@Suite("MockRun-driven tracking")
struct MockRunTrackingTests {

    private let startCentre = MockSurfaceMaps.keypadButton(.start).bounds.center

    @Test("the same preset yields identical frames every time", arguments: MockRun.Preset.allCases)
    func deterministic(preset: MockRun.Preset) {
        let a = MockTrackingSource(run: preset.run).allFrames()
        let b = MockTrackingSource(run: preset.run).allFrames()
        let c = preset.run.frames(target: startCentre, baseTimestamp: MockTrackingSource.fixedEpoch)

        #expect(a.count == 121, "2 s travel + 2 s hold at 30 Hz, both ends inclusive")
        #expect(a == b)
        #expect(a == c)
    }

    @Test("30 Hz from the fixed epoch", arguments: MockRun.Preset.allCases)
    func timing(preset: MockRun.Preset) {
        let source = MockTrackingSource(run: preset.run)
        #expect(source.interval == .seconds(1) / 30)
        #expect(source.steps == 120)
        for (tick, frame) in source.allFrames().enumerated() {
            #expect(frame.timestamp == MockTrackingSource.fixedEpoch.addingTimeInterval(Double(tick) / 30))
        }
    }

    @Test("straight: starts at start, arrives at tick 60, holds for 2 s")
    func straight() {
        let source = MockTrackingSource(run: .straight)
        let frames = source.allFrames()

        #expect(source.target == startCentre)
        #expect(frames[0].fingertip == MockRun.straight.start)
        #expect(frames[59].fingertip != startCentre)
        #expect(frames[60...].allSatisfy { $0.fingertip == startCentre })
        #expect(frames.allSatisfy { $0.trackingQuality == .good })
    }

    @Test("the wobble stays within 0.01 of the straight line")
    func wobble() {
        let run = MockRun.straight
        let path = run.start.vector(to: startCentre)
        let normal = PanelVector(dx: -path.dy, dy: path.dx).normalized!
        var largest = 0.0
        for frame in MockTrackingSource(run: run).allFrames() {
            let offset = run.start.vector(to: frame.fingertip!)
            largest = max(largest, abs(offset.dx * normal.dx + offset.dy * normal.dy))
        }
        #expect(largest <= MockRun.wobbleAmplitude + 1e-12)
        #expect(largest > MockRun.wobbleAmplitude / 2, "there is a visible wobble")
    }

    @Test("overshoot passes 0.1 beyond the target, then returns")
    func overshoot() {
        let run = MockRun.overshoot
        let frames = MockTrackingSource(run: run).allFrames()
        let path = run.start.vector(to: startCentre).normalized!

        let peak = frames[45].fingertip!  // 75% of the 60 travel ticks
        let past = startCentre.vector(to: peak)
        #expect(abs(past.dx * path.dx + past.dy * path.dy - 0.1) < 1e-9, "0.1 beyond, along the path")
        #expect(frames[60...].allSatisfy { $0.fingertip == startCentre })
    }

    @Test("withDropout: 0.5 s lost in the middle of the reach")
    func dropout() {
        let frames = MockTrackingSource(run: .withDropout).allFrames()
        let lostTicks = frames.indices.filter { frames[$0].trackingQuality == .lost }

        #expect(lostTicks == Array(23...37), "15 frames = 0.5 s at 30 Hz")
        #expect(lostTicks.allSatisfy { frames[$0].fingertip == nil })
        #expect(frames[22].fingertip != nil && frames[38].fingertip != nil)
        // Outside the window it is the straight run, frame for frame.
        let straight = MockTrackingSource(run: .straight).allFrames()
        for tick in frames.indices where !lostTicks.contains(tick) {
            #expect(frames[tick] == straight[tick])
        }
    }

    @Test("the legacy walk is untouched by the new init")
    func legacyUnchanged() {
        let legacy = MockTrackingSource()
        #expect(legacy.run == nil)
        #expect(legacy.steps == 30)
        #expect(legacy.frame(atStep: 0).fingertip == PanelPoint(x: 0.12, y: 0.14))
        #expect(legacy.frame(atStep: 30).fingertip == MockSurfaceMaps.microwaveStartButton.bounds.center)
        #expect(legacy.allFrames().count == 31)
    }

    @Test("streaming yields allFrames() and never runs early")
    func streams() async {
        let run = MockRun(start: .center, targetButtonID: Key.stop.id, duration: 0.2, hold: 0.1)
        let source = MockTrackingSource(run: run)

        let clock = ContinuousClock()
        let began = clock.now
        var streamed: [TrackingFrame] = []
        for await frame in source.frames() { streamed.append(frame) }

        #expect(streamed == source.allFrames())
        #expect(began.duration(to: clock.now) >= source.interval * source.steps)
    }

    @Test("dropping out of the stream early stops it")
    func cancels() async {
        var count = 0
        for await _ in MockTrackingSource(run: .straight).frames() {
            count += 1
            if count == 2 { break }
        }
        #expect(count == 2)
    }
}

@Suite("MockGuidanceSource")
struct MockGuidanceSourceTests {

    @Test("states are GuidanceMath over the run's frames", arguments: MockRun.Preset.allCases)
    func chained(preset: MockRun.Preset) {
        let source = MockGuidanceSource(run: preset.run)
        let frames = source.tracking.allFrames()
        let states = source.allStates()

        #expect(states.count == frames.count)
        #expect(states == frames.map { GuidanceMath.compute(frame: $0, target: source.target) })
        #expect(states == MockGuidanceSource(run: preset.run).allStates(), "deterministic")
        #expect(states.last?.outcome == .arrived)
        #expect(source.state(atStep: 0) == states[0])
    }

    @Test("the first state points down-right toward Start; dropout reads lostTracking")
    func content() {
        let first = MockGuidanceSource(run: .straight).state(atStep: 0)
        #expect(first.outcome == nil)
        #expect(PrintingFeedbackEngine.compass(first.vector!.direction) == "down-right")

        let dropout = MockGuidanceSource(run: .withDropout).allStates()
        #expect(dropout[23...37].allSatisfy { $0.outcome == .lostTracking })
    }

    @Test("streams one state per frame, then finishes")
    func streams() async {
        let run = MockRun(start: .center, targetButtonID: Key.popcorn.id, duration: 0.1, hold: 0.1)
        let source = MockGuidanceSource(run: run)

        var streamed: [GuidanceState] = []
        for await state in source.states() { streamed.append(state) }

        #expect(streamed == source.allStates())
    }
}
