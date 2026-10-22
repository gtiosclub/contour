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
    private(set) var tracking: any TrackingSource
    let sessionFactory: GuidanceSessionFactory
    private let sessionCamera: (any CameraFrameSource)?
    private(set) var trackingSettings: GuidanceTrackingSettings
    var trackingMethod: PanelTrackingMethod { trackingSettings.method }
    var featureOptions: FeatureTrackingOptions { trackingSettings.options }
    private(set) var trackingReady = true
    let feedback: any FeedbackEngine

    /// The reference whose map and live tracking belong to the current session.
    private(set) var panelReference: PanelReference?
    private(set) var trackingError: String?
    private(set) var hybridStatus: HybridTrackingDiagnostics?
    private var generation: UInt64 = 0
    private var guidanceTask: Task<Void, Never>?
    private var guidanceGeneration: UInt64?

    var canGuide: Bool {
        guard let reference = panelReference else { return false }
        return trackingReady && (!liveComponents.contains(.tracking) || reference.detection.quad != .fullFrame)
    }

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
        liveComponents: Set<Component>,
        sessionFactory: @escaping GuidanceSessionFactory = GuidanceSessionFactories.vision,
        sessionCamera: (any CameraFrameSource)? = nil,
        trackingMethod: PanelTrackingMethod = .vision,
        featureOptions: FeatureTrackingOptions = FeatureTrackingOptions()
    ) {
        self.sessionFactory = sessionFactory
        self.sessionCamera = sessionCamera
        self.trackingSettings = GuidanceTrackingSettings(method: trackingMethod, options: featureOptions)
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
            liveComponents: Set(Component.allCases), sessionCamera: camera
        )
    }

    /// Independent UI work supplies scripted sessions; assembly supplies the
    /// real factory. Construction errors remain explicit to the caller.
    static func live(camera: any CameraFrameSource, sessionFactory: @escaping GuidanceSessionFactory,
                     method: PanelTrackingMethod = .hybrid,
                     options: FeatureTrackingOptions = FeatureTrackingOptions()) throws -> ContourPipeline {
        ContourPipeline(surfaceUnderstanding: LiveSurfaceUnderstanding(),
            tracking: try sessionFactory(camera, method, options, nil),
            feedback: LiveFeedbackEngine(), liveComponents: Set(Component.allCases), sessionFactory: sessionFactory,
            sessionCamera: camera, trackingMethod: method, featureOptions: options)
    }

    // MARK: Session

    /// Detect the panel in `photo`.
    func detectPanel(in photo: PanelPhoto) async throws -> SurfaceMap {
        generation &+= 1
        let scan = generation
        panelReference = nil
        trackingError = nil
        hybridStatus = nil
        trackingReady = false
        await cancelGuidance()
        guard generation == scan, !Task.isCancelled else { throw CancellationError() }
        let detection = try await surfaceUnderstanding.detectPanel(from: photo)
        guard generation == scan, !Task.isCancelled else { throw CancellationError() }
        let reference = try PanelReference(photo: photo, detection: detection)
        let activation = beginSessionReplacement(with: reference)
        await withTaskCancellationHandler {
            await activation.value
        } onCancel: {
            activation.cancel()
        }
        guard panelReference?.photo.id == reference.photo.id, !Task.isCancelled else {
            throw CancellationError()
        }
        return detection.map
    }

    /// Shared handoff for manual setup and replacement. Previous guidance ends
    /// before a different reference or target can be used.
    func replaceReference(with reference: PanelReference) async {
        let activation = beginSessionReplacement(with: reference)
        await withTaskCancellationHandler {
            await activation.value
        } onCancel: {
            activation.cancel()
        }
    }

    /// Called by settings controls (including Diagnostics). The requested
    /// configuration becomes authoritative synchronously, before any async
    /// factory or registration work can finish out of order. Await the returned
    /// task to observe completion; the UI may simply let it run.
    @discardableResult
    func requestTrackingSettings(method: PanelTrackingMethod,
                                 options: FeatureTrackingOptions) -> Task<Void, Never> {
        trackingSettings = GuidanceTrackingSettings(method: method, options: options)
        return beginSessionReplacement(with: panelReference)
    }

    private func beginSessionReplacement(with reference: PanelReference?) -> Task<Void, Never> {
        generation &+= 1
        let replacement = generation
        panelReference = reference
        trackingError = nil
        hybridStatus = nil
        trackingReady = false
        // An old stream may still be unwinding; it holds its own source. New
        // guidance must never subscribe to it while replacement is pending.
        if sessionCamera != nil { tracking = InactiveTrackingSource() }
        return Task { await activateSession(request: replacement, reference: reference) }
    }

    private func activateSession(request: UInt64, reference: PanelReference?) async {
        await cancelGuidance()
        guard generation == request, !Task.isCancelled else { return }
        do {
            if let sessionCamera {
                // A new factory call owns a new tracker. Diagnostics makes its
                // own call with these settings and never shares this session.
                let candidate = try sessionFactory(sessionCamera, trackingMethod, featureOptions, nil)
                if let reference { await candidate.use(reference) }
                guard generation == request, !Task.isCancelled else { return }
                tracking = candidate
            } else if let reference, let live = tracking as? any GuidanceTrackingSession {
                await live.use(reference)
                guard generation == request, !Task.isCancelled else { return }
            }
            trackingReady = true
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            // Keep the requested mode visible. An unsupported mode or failed
            // factory cannot quietly continue using the old tracker.
            trackingError = error.localizedDescription
        }
    }

    /// Stop guidance without discarding the reference, so it can be retried.
    func stopGuidance() async {
        generation &+= 1
        await cancelGuidance()
    }

    private func cancelGuidance() async {
        let old = guidanceTask
        let oldGeneration = guidanceGeneration
        old?.cancel()
        await old?.value
        if guidanceGeneration == oldGeneration {
            guidanceTask = nil
            guidanceGeneration = nil
        }
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
        guard trackingReady else { return }
        generation &+= 1
        let session = generation
        await cancelGuidance()
        guard generation == session, !Task.isCancelled else { return }
        if let reference = panelReference {
            guard canGuide, reference.detection.map.buttons.contains(where: { $0.id == target.id }) else { return }
        } else if liveComponents.contains(.tracking) {
            return
        }
        let source = tracking
        let task = Task { await self.runGuidance(to: target, session: session, source: source) }
        guidanceTask = task
        guidanceGeneration = session
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if guidanceGeneration == session {
            guidanceTask = nil
            guidanceGeneration = nil
        }
    }

    private func runGuidance(to target: SurfaceMap.Button, session: UInt64,
                             source: any TrackingSource) async {
        var announced: OutcomeSignal?
        var lostSince: Date?
        var arrived = false
        for await frame in source.frames() {
            if Task.isCancelled || generation != session { break }
            if let live = source as? any GuidanceTrackingSession {
                let failure = await live.registrationError()
                let status = await live.hybridStatus()
                guard generation == session, !Task.isCancelled else { break }
                hybridStatus = status
                switch failure {
                case .invalidReferenceQuad:
                    trackingError = "Tracking could not initialize: the panel corners are invalid. Prepare a new reference."
                case .unreadableReferencePhoto:
                    trackingError = "Tracking could not read the reference photo. Capture a new reference."
                case .registrationFailed:
                    trackingError = "Vision could not track the marked panel in the reference photo. Capture again and mark its actual boundary."
                default:
                    trackingError = nil
                }
            }
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

/// No frames while the requested session is being built or cannot be built.
private struct InactiveTrackingSource: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> { AsyncStream { $0.finish() } }
}
