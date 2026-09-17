//
//  ContourPipeline.swift
//  ContourApp — Experience / Mocks & Integration
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  THE WIRING. This file is where the team packages are assembled, and it  │
//  │  is the only file in the repo that imports more than one of them.        │
//  │                                                                          │
//  │  Teams: you do not need to edit this to work. Build against the          │
//  │  protocols in your own package and flip your line below when you are     │
//  │  ready to be switched on.                                                │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  The dependency rule, restated: SurfaceUnderstanding, Tracking,
//  ContourFeedback and ContourUI each depend on ContourCore and nothing else.
//  None of them can see each other — not even ContourFeedback and ContourUI,
//  which Experience owns both of. This file can see all of them. That
//  asymmetry is the entire architecture.
//

import ContourCore
import ContourFeedback
import ContourMocks
import ContourUI
import Observation
import SurfaceUnderstanding
import SwiftUI
import Tracking

/// Holds one implementation of each protocol and runs a guidance session.
@MainActor
@Observable
final class ContourPipeline {

    let surfaceUnderstanding: any ContourCore.SurfaceUnderstanding
    let tracking: any TrackingSource
    let feedback: any FeedbackEngine

    /// Which of the three are real implementations rather than mocks. Rendered
    /// on the placeholder screen so the state of the project is visible at a
    /// glance on day one.
    let liveComponents: Set<Component>

    enum Component: String, CaseIterable, Sendable {
        case surfaceUnderstanding = "Surface Understanding"
        case tracking = "Tracking"
        case feedback = "Feedback"

        var team: String {
            switch self {
            case .surfaceUnderstanding: "Surface Understanding"
            case .tracking: "Tracking / Spatial"
            case .feedback: "Experience"
            }
        }
    }

    init(
        surfaceUnderstanding: any ContourCore.SurfaceUnderstanding,
        tracking: any TrackingSource,
        feedback: any FeedbackEngine,
        liveComponents: Set<Component>
    ) {
        self.surfaceUnderstanding = surfaceUnderstanding
        self.tracking = tracking
        self.feedback = feedback
        self.liveComponents = liveComponents
    }

    // MARK: Configurations

    /// Everything mocked. This is what the app runs on until Week 4.
    static func mock() -> ContourPipeline {
        ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: MockTrackingSource(),
            feedback: PrintingFeedbackEngine(),
            liveComponents: []
        )
    }

    /// Everything real.
    ///
    /// Do not call this yet — the live types are `fatalError` stubs and this
    /// will crash on first use. It exists so the switchover is a one-line
    /// change and so the live types stay compiled and linked from day one.
    ///
    /// Teams: as your package comes up, move your line from `mock()` into here
    /// and add your `Component` to `liveComponents`. Mixed configurations are
    /// expected and fine — that is the point of mocking per protocol.
    static func live() -> ContourPipeline {
        ContourPipeline(
            surfaceUnderstanding: LiveSurfaceUnderstanding(),
            tracking: LiveTrackingSource(),
            feedback: LiveFeedbackEngine(),
            liveComponents: Set(Component.allCases)
        )
    }

    // MARK: Session

    /// Detect the panel in `photo`.
    func detectPanel(in photo: PanelPhoto) async throws -> SurfaceMap {
        try await surfaceUnderstanding.surfaceMap(from: photo)
    }

    /// Guide the user's finger to `target` until the stream ends or the task is
    /// cancelled.
    ///
    /// The whole pipeline in five lines: frames in from Tracking, composed into
    /// guidance, out to Experience. The composition step is
    /// `MockGuidance` — placeholder wiring that gets replaced once the real
    /// guidance policy has an owner. See MockGuidance.swift.
    func guide(to target: SurfaceMap.Button) async {
        for await frame in tracking.frames() {
            if Task.isCancelled { return }
            await feedback.present(MockGuidance.state(for: frame, target: target))
        }
    }
}
