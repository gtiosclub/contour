//
//  MockTrackingSource.swift
//  ContourMocks
//
//  Tracking's stand-in. Walks a fingertip from a start point to a target on a
//  timer and finishes. Fully deterministic: the whole sequence is a pure
//  function of the initialiser arguments, including the timestamps.
//
//  Two ways to drive it:
//  - the original linear walk, `MockTrackingSource(start:target:steps:...)`,
//    which the app, the Harness and other teams' tests pin; and
//  - a `MockRun` script, `MockTrackingSource(run:map:)` (issue #12): 30 Hz,
//    ease-in-out with a small wobble, optional overshoot and dropout, then a
//    2 s hold on the target.
//  Both stream on a ContinuousClock, sleeping until each tick's deadline so
//  the frame rate does not drift.
//
//  COORDINATES: `fingertip` is in normalized panel space, (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A `TrackingSource` that walks a fingertip toward a target and then stops.
///
/// Emits `steps + 1` frames, `interval` apart: frame `0` at `start`, frame
/// `steps` exactly on `target`, linearly interpolated in between.
///
/// Deterministic in every respect:
/// - positions are a linear interpolation, not a simulation;
/// - timestamps count forward from `baseTimestamp`, not from `Date()`;
/// - any jitter comes from `SeededGenerator` and is off by default.
///
/// So two runs of the same configuration produce byte-identical frames, and a
/// test can assert on frame 7 by name.
public struct MockTrackingSource: TrackingSource {

    /// Where the fingertip starts. Default is up and to the left of the panel's
    /// centre, so the first guidance vector points down-and-right.
    public let start: PanelPoint

    /// Where the fingertip ends up. Default is the centre of the canned
    /// microwave's "Start" button.
    public let target: PanelPoint

    /// How many steps the walk takes. `steps + 1` frames are emitted.
    public let steps: Int

    /// Wall-clock gap between frames. Default is roughly 30 fps.
    public let interval: Duration

    /// Timestamp of frame `0`. Fixed by default so runs are reproducible.
    public let baseTimestamp: Date

    /// Quality reported for every frame except those named in `qualityOverrides`.
    public let quality: TrackingQuality

    /// Per-step quality overrides, keyed by frame index.
    ///
    /// Use this to script a dropout without touching any real tracking code:
    /// `[12: .degraded, 13: .lost, 14: .lost]`. A frame whose quality is `.lost`
    /// reports a `nil` fingertip, exactly as the real source must.
    public let qualityOverrides: [Int: TrackingQuality]

    /// Maximum positional wobble added to each frame, in panel units. `0` by
    /// default. When non-zero it is drawn from `SeededGenerator` with `seed`,
    /// so it is still reproducible.
    public let jitter: Double

    /// Seed for `jitter`. Change it to get a different — but still fixed — walk.
    public let seed: UInt64

    /// The script driving this source, if it was made with `init(run:map:)`.
    /// `nil` for the original linear walk.
    public let run: MockRun?

    public init(
        start: PanelPoint = PanelPoint(x: 0.12, y: 0.14),
        target: PanelPoint = MockSurfaceMaps.microwaveStartButton.bounds.center,
        steps: Int = 30,
        interval: Duration = .milliseconds(33),
        baseTimestamp: Date = MockTrackingSource.fixedEpoch,
        quality: TrackingQuality = .good,
        qualityOverrides: [Int: TrackingQuality] = [:],
        jitter: Double = 0,
        seed: UInt64 = SeededGenerator.contourSeed
    ) {
        precondition(steps > 0, "a walk needs at least one step")
        self.start = start
        self.target = target
        self.steps = steps
        self.interval = interval
        self.baseTimestamp = baseTimestamp
        self.quality = quality
        self.qualityOverrides = qualityOverrides
        self.jitter = jitter
        self.seed = seed
        self.run = nil
    }

    /// A 30 Hz source that plays `run` toward its target button in `map`.
    ///
    /// `start` is the run's start, `target` the button's centre, `steps` the
    /// run's `lastTick` (travel plus the hold) and `interval` 1/30 s.
    /// `qualityOverrides` and `jitter` do not apply; the run's own `dropout`
    /// and wobble do.
    ///
    /// - Precondition: `run.targetButtonID` is a button in `map`.
    public init(
        run: MockRun,
        map: SurfaceMap = MockSurfaceMaps.microwaveKeypad,
        baseTimestamp: Date = MockTrackingSource.fixedEpoch
    ) {
        guard let button = map.buttons.first(where: { $0.id == run.targetButtonID }) else {
            preconditionFailure("MockRun target \(run.targetButtonID) is not a button in the map")
        }
        self.start = run.start
        self.target = button.bounds.center
        self.steps = run.lastTick
        self.interval = .seconds(1) / MockRun.framesPerSecond
        self.baseTimestamp = baseTimestamp
        self.quality = .good
        self.qualityOverrides = [:]
        self.jitter = 0
        self.seed = SeededGenerator.contourSeed
        self.run = run
    }

    /// 2026-01-01 00:00:00 UTC. An arbitrary fixed instant, so that mock
    /// timestamps never depend on when the test ran.
    public static let fixedEpoch = Date(timeIntervalSince1970: 1_767_225_600)

    /// The frame this source emits at `step`, computed directly.
    ///
    /// Exposed so tests can assert on a frame without draining the stream, and
    /// so the Harness can scrub rather than play.
    public func frame(atStep step: Int) -> TrackingFrame {
        if let run {
            return run.frame(atTick: step, target: target, baseTimestamp: baseTimestamp)
        }

        let clamped = min(max(step, 0), steps)
        let frameQuality = qualityOverrides[clamped] ?? quality
        let timestamp = baseTimestamp.addingTimeInterval(
            Double(clamped) * interval.seconds
        )

        guard frameQuality != .lost else {
            return TrackingFrame(
                timestamp: timestamp,
                fingertip: nil,
                panel: .unknown,
                trackingQuality: .lost
            )
        }

        let t = Double(clamped) / Double(steps)
        var point = PanelPoint(
            x: start.x + (target.x - start.x) * t,
            y: start.y + (target.y - start.y) * t
        )

        if jitter != 0 {
            // Seeded per step, so `frame(atStep: 7)` is the same value however
            // many times and in whatever order it is called.
            var generator = SeededGenerator(seed: seed &+ UInt64(clamped))
            point.x += generator.symmetric(jitter)
            point.y += generator.symmetric(jitter)
        }

        return TrackingFrame(
            timestamp: timestamp,
            fingertip: point,
            panel: MockTrackingSource.pose(for: frameQuality),
            trackingQuality: frameQuality
        )
    }

    /// Every frame this source emits, `0...steps`, computed directly with no
    /// clock. This is what determinism tests should compare.
    public func allFrames() -> [TrackingFrame] {
        (0...steps).map(frame(atStep:))
    }

    /// Streams `allFrames()` in real time, `interval` apart.
    ///
    /// Tick `n` is yielded at `start + n * interval` on a `ContinuousClock`;
    /// sleeping until each absolute deadline rather than for a fixed gap means
    /// a slow tick does not push every later tick back. Cancelling the
    /// consumer (or dropping the stream) cancels the producing task.
    public func frames() -> AsyncStream<TrackingFrame> {
        let source = self
        return AsyncStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let origin = clock.now
                for step in 0...source.steps {
                    if Task.isCancelled { break }
                    continuation.yield(source.frame(atStep: step))
                    guard step < source.steps else { break }
                    do {
                        try await clock.sleep(until: origin.advanced(by: source.interval * (step + 1)))
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A plausible pose: panel 40 cm in front of the camera, square on.
    private static func pose(for quality: TrackingQuality) -> PanelPose {
        PanelPose(
            column0: SIMD4(1, 0, 0, 0),
            column1: SIMD4(0, 1, 0, 0),
            column2: SIMD4(0, 0, 1, 0),
            column3: SIMD4(0, 0, -0.4, 1),
            confidence: quality == .good ? 0.92 : 0.44
        )
    }
}

extension Duration {
    /// This duration in seconds, as a `Double`.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
