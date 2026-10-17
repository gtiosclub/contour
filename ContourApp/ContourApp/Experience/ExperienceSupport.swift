//
//  ExperienceSupport.swift
//  ContourApp — Experience / Accessibility & Launch
//
//  The app flow's small pure decisions, kept out of the views so ContourTests
//  can pin them: when guidance has ended which way, what a scan result means,
//  and the DEBUG screenshot stages.
//

import ContourCore
import ContourMocks
import ContourUI
import Foundation

/// How the app turns pipeline results into flow stages.
nonisolated enum ExperiencePolicy {

    /// A panel read with less confidence than this is `.lowConfidence`, not a
    /// selection. Deliberately low: Surface's own full-frame fallback reports
    /// 0.6, and a usable panel should never be refused here.
    static let minimumPanelConfidence = 0.3

    /// How long tracking may stay lost while guiding before the session ends
    /// with `.lostTracking`. Shorter losses recover by themselves.
    static let lostTrackingTimeout: Duration = .seconds(10)

    /// The shortest time the "Reading the panel" screen stays up, so it never
    /// flashes and its announcement is heard before the next one.
    static let minimumDetectingTime: Duration = .seconds(1.2)

    /// What a finished scan leads to.
    enum ScanResult: Equatable {
        /// Show the controls.
        case select
        /// Back to aiming, saying why.
        case retry(String)
        /// A panel, but too unsure to use.
        case lowConfidence
    }

    static func scanResult(map: SurfaceMap, canGuide: Bool) -> ScanResult {
        if !canGuide {
            #if DEBUG
            return .retry("Surface did not return a trackable panel outline. Try showing the full panel, or use Manual Tracking Test in the debug menu to test tracking independently.")
            #else
            return .retry("Surface did not return a trackable panel outline. Try showing the full panel, then scan again.")
            #endif
        }
        if map.buttons.isEmpty {
            return .retry("No buttons were found. Move a little closer, straight on, and scan again.")
        }
        if map.confidence < minimumPanelConfidence { return .lowConfidence }
        return .select
    }

    /// How a guidance session that ended by itself — not by Stop — finished.
    ///
    /// `pipeline.guide(to:)` returns when the finger arrives or the tracking
    /// stream ends. If it ended without arriving, the last thing announced says
    /// why; with nothing announced, the stream simply went away, which to the
    /// user is the panel being lost.
    static func outcome(afterGuidanceEndedWith last: OutcomeSignal?) -> OutcomeSignal {
        switch last {
        case .arrived?: .arrived
        case .lowConfidence?: .lowConfidence
        case .lostTracking?, .notFound?, nil: .lostTracking
        }
    }

    /// Roughly where the finger is, for drawing it on the Simulator's
    /// placeholder panel only. Inverts MockGuidance (distance over the panel
    /// diagonal); a real guidance policy may differ, so never use this for
    /// anything but a picture.
    static func approximateFingertip(target: SurfaceMap.Button, guidance: GuidanceState?) -> PanelPoint? {
        guard let vector = guidance?.vector else { return nil }
        let distance = vector.normalizedDistance * 2.0.squareRoot()
        let centre = target.bounds.center
        return PanelPoint(x: centre.x - vector.direction.dx * distance,
                          y: centre.y - vector.direction.dy * distance)
    }
}

#if DEBUG
/// Launch straight into one stage with mock data, for screenshots and demos.
///
/// Pass as a launch argument (Scheme ▸ Run ▸ Arguments, or `simctl launch`):
///
///     -ContourDemoStage acquire | detecting | select | guide
///                     | arrived | lostTracking | notFound | lowConfidence
///
/// The flow is walked there through legal transitions with the six-button mock
/// microwave and the Start button; from then on the app works normally.
nonisolated enum DemoStage: String, CaseIterable, Sendable {
    case acquire, detecting, select, guide, arrived, lostTracking, notFound, lowConfidence

    static let launchArgument = "ContourDemoStage"

    /// The stage named on the command line, if any.
    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> DemoStage? {
        defaults.string(forKey: launchArgument).flatMap(DemoStage.init(rawValue:))
    }

    static let map = MockSurfaceMaps.microwave
    static let target = MockSurfaceMaps.microwaveStartButton

    /// A frozen moment of guidance: Start is below and to the right, fairly close.
    static let guidance = GuidanceState(
        timestamp: MockTrackingSource.fixedEpoch,
        vector: GuidanceVector(direction: PanelVector(dx: 0.6, dy: 0.8), normalizedDistance: 0.22)
    )

    /// The legal route from `.idle` to this stage.
    var route: [GuidanceFlowStage] {
        let selecting: [GuidanceFlowStage] = [.acquiringPanel, .detecting, .selectingTarget(Self.map)]
        switch self {
        case .acquire: return [.acquiringPanel]
        case .detecting: return [.acquiringPanel, .detecting]
        case .select: return selecting
        case .guide: return selecting + [.guiding(Self.target)]
        case .notFound: return selecting + [.finished(.notFound)]
        case .arrived: return selecting + [.guiding(Self.target), .finished(.arrived)]
        case .lostTracking: return selecting + [.guiding(Self.target), .finished(.lostTracking)]
        case .lowConfidence: return selecting + [.guiding(Self.target), .finished(.lowConfidence)]
        }
    }
}
#endif
