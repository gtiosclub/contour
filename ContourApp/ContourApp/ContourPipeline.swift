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

    /// Retained for future live tracker initialization; live tracking is still a stub.
    private(set) var panelReference: PanelReference?

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

    /// Real Surface Understanding (panel, buttons and labels) and real feedback
    /// (haptics), mock tracking. Use this to run everything that is live today
    /// before tracking is.
    ///
    /// Unlike `mock()`, this can throw from `detectPanel(in:)`: a photo with no
    /// panel in it fails here, as it should.
    static func realPanel() -> ContourPipeline {
        ContourPipeline(
            surfaceUnderstanding: LiveSurfaceUnderstanding(),
            tracking: MockTrackingSource(),
            feedback: LiveFeedbackEngine(),
            liveComponents: [.surfaceUnderstanding, .feedback]
        )
    }

    /// Everything real, on `camera`: Surface Understanding reads the panel,
    /// Tracking follows it and the fingertip, and guidance vibrates.
    static func live(camera: CameraService) -> ContourPipeline {
        ContourPipeline(
            surfaceUnderstanding: LiveSurfaceUnderstanding(),
            tracking: LiveTrackingSource(camera: camera),
            feedback: LiveFeedbackEngine(),
            liveComponents: Set(Component.allCases)
        )
    }

    // MARK: Session

    /// Detect the panel in `photo`.
    func detectPanel(in photo: PanelPhoto) async throws -> SurfaceMap {
        panelReference = nil
        let detection = try await surfaceUnderstanding.detectPanel(from: photo)
        let reference = try PanelReference(photo: photo, detection: detection)
        panelReference = reference
        // Live tracking follows the panel just found.
        if let live = tracking as? LiveTrackingSource {
            await live.use(reference)
        }
        return detection.map
    }

    /// Guide the user's finger to `target` until the stream ends or the task is
    /// cancelled.
    ///
    /// The whole pipeline in five lines: frames in from Tracking, composed into
    /// guidance, out to Experience. The composition step is
    /// `MockGuidance` — placeholder wiring that gets replaced once the real
    /// guidance policy has an owner. See MockGuidance.swift.
    ///
    /// An outcome is presented once, not on every frame it stays true. Losing
    /// the panel is announced once it has been gone for 0.3 s, then guidance
    /// picks up again when it's back. Arriving ends the session, and any other
    /// ending stops the vibration.
    func guide(to target: SurfaceMap.Button) async {
        var announced: OutcomeSignal?
        var lostSince: Date?
        var arrived = false
        for await frame in tracking.frames() {
            if Task.isCancelled { break }
            let state = MockGuidance.state(for: frame, target: target)

            // A frame or two of blur isn't worth announcing: say the panel is
            // lost only once it has been gone for a moment.
            if state.outcome == .lostTracking {
                let since = lostSince ?? frame.timestamp
                lostSince = since
                if frame.timestamp.timeIntervalSince(since) < 0.3 { continue }
            } else {
                lostSince = nil
            }

            if let outcome = state.outcome, outcome == announced { continue }
            announced = state.outcome
            await feedback.present(state)
            if state.outcome == .arrived {
                arrived = true
                break
            }
        }
        if !arrived {
            // Stopping, or the camera going away, must not leave the vibration
            // running.
            await feedback.present(GuidanceState(timestamp: Date(), vector: nil))
        }
    }
}
