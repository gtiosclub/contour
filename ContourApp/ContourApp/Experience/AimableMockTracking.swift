//
//  AimableMockTracking.swift
//  ContourApp — Experience / Mocks & Integration
//
//  The mock pipeline's tracking (and so the Simulator's): ContourMocks'
//  deterministic MockTrackingSource, re-aimed at whichever control the user
//  chose and slowed to a pace you can watch — about four seconds from the
//  bottom of the panel to the target. Still fully deterministic: the walk is a
//  pure function of the target.
//
//  COORDINATES: normalized panel space, (0,0) top-left, y DOWN.
//

import ContourCore
import ContourMocks
import Foundation
import Synchronization

nonisolated final class AimableMockTracking: TargetAwareTrackingSource {

    private let target = Mutex(MockSurfaceMaps.microwaveStartButton.bounds.center)

    /// Frames in one walk, and the gap between them.
    let steps: Int
    let interval: Duration

    init(steps: Int = 100, interval: Duration = .milliseconds(40)) {
        self.steps = steps
        self.interval = interval
    }

    func aim(at button: SurfaceMap.Button) async {
        target.withLock { $0 = button.bounds.center }
    }

    func frames() -> AsyncStream<TrackingFrame> {
        let goal = target.withLock { $0 }
        return MockTrackingSource(start: Self.start(toward: goal), target: goal,
                                  steps: steps, interval: interval).frames()
    }

    /// Below the panel's bottom edge, on the side away from the target, so the
    /// arrow has somewhere interesting to point.
    static func start(toward goal: PanelPoint) -> PanelPoint {
        PanelPoint(x: goal.x < 0.5 ? 0.85 : 0.15, y: 1.05)
    }
}
