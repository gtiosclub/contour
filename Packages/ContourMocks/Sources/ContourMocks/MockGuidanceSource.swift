//
//  MockGuidanceSource.swift
//  ContourMocks — Experience / Mocks & Integration
//
//  MockTrackingSource -> GuidanceMath, chained: a 30 Hz stream of
//  GuidanceState for feeding a FeedbackEngine (or a debug screen) without a
//  camera, a tracker or a guidance model. Deterministic like everything here.
//
//  COORDINATES: normalized panel space, y DOWNWARD.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A `GuidanceState` stream: a `MockTrackingSource` run through
/// `GuidanceMath.compute(frame:target:)`, one state per frame.
public struct MockGuidanceSource: Sendable {

    /// Where the frames come from.
    public let tracking: MockTrackingSource

    /// The button guidance points at.
    public let target: SurfaceMap.Button

    /// Passed to `GuidanceMath.compute(frame:target:arrivalRadius:)`.
    public let arrivalRadius: Double

    public init(
        tracking: MockTrackingSource,
        target: SurfaceMap.Button,
        arrivalRadius: Double = GuidanceMath.defaultArrivalRadius
    ) {
        self.tracking = tracking
        self.target = target
        self.arrivalRadius = arrivalRadius
    }

    /// Plays `run` against `map` at 30 Hz and guides toward its target button.
    ///
    /// - Precondition: `run.targetButtonID` is a button in `map`.
    public init(
        run: MockRun = .straight,
        map: SurfaceMap = MockSurfaceMaps.microwaveKeypad,
        baseTimestamp: Date = MockTrackingSource.fixedEpoch,
        arrivalRadius: Double = GuidanceMath.defaultArrivalRadius
    ) {
        guard let button = map.buttons.first(where: { $0.id == run.targetButtonID }) else {
            preconditionFailure("MockRun target \(run.targetButtonID) is not a button in the map")
        }
        self.init(
            tracking: MockTrackingSource(run: run, map: map, baseTimestamp: baseTimestamp),
            target: button,
            arrivalRadius: arrivalRadius
        )
    }

    /// The state for tracking frame `step`, computed directly.
    public func state(atStep step: Int) -> GuidanceState {
        GuidanceMath.compute(
            frame: tracking.frame(atStep: step),
            target: target,
            arrivalRadius: arrivalRadius
        )
    }

    /// Every state, one per tracking frame, with no clock.
    public func allStates() -> [GuidanceState] {
        tracking.allFrames().map {
            GuidanceMath.compute(frame: $0, target: target, arrivalRadius: arrivalRadius)
        }
    }

    /// Streams one state per tracking frame, at the tracking source's rate
    /// (30 Hz for a `MockRun`). Ends when the run ends; cancelling the consumer
    /// cancels the underlying tracking stream too.
    public func states() -> AsyncStream<GuidanceState> {
        let tracking = tracking
        let target = target
        let arrivalRadius = arrivalRadius
        return AsyncStream { continuation in
            let task = Task {
                for await frame in tracking.frames() {
                    if Task.isCancelled { break }
                    continuation.yield(
                        GuidanceMath.compute(frame: frame, target: target, arrivalRadius: arrivalRadius)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
