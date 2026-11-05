import ContourCore
import Foundation
import Tracking

/// App-local capabilities shared by real tracking and scripted UI sessions.
/// No concrete-source casts are needed for reference handoff or diagnostics.
nonisolated protocol GuidanceTrackingSession: TrackingSource {
    func use(_ reference: PanelReference) async
    func registrationError() async -> PanelTrackingError?
    func hybridStatus() async -> HybridTrackingDiagnostics?
}

extension LiveTrackingSource: GuidanceTrackingSession {}

/// Each invocation must create an independent session. The callback runs on
/// the tracking worker and must enqueue promptly rather than render UI there.
typealias GuidanceSessionFactory = @MainActor (
    any CameraFrameSource,
    PanelTrackingMethod,
    FeatureTrackingOptions,
    (@Sendable (LiveTrackingSample) -> Void)?
) throws -> any GuidanceTrackingSession

/// The app's requested tracking configuration. Diagnostics reads the same
/// value, but asks the factory for its own independent session.
struct GuidanceTrackingSettings: Hashable, Sendable {
    var method: PanelTrackingMethod
    var options: FeatureTrackingOptions

    init(method: PanelTrackingMethod = .hybrid,
         options: FeatureTrackingOptions = FeatureTrackingOptions()) {
        self.method = method
        self.options = options
    }
}

nonisolated enum GuidanceSessionFactoryError: LocalizedError, Equatable {
    case unimplemented(PanelTrackingMethod)

    var errorDescription: String? {
        switch self {
        case .unimplemented(let method): "\(method.rawValue) has not been implemented yet. Use Vision tracking."
        }
    }
}

enum GuidanceSessionFactories {
    /// Guidance and diagnostics create separate trackers with identical settings.
    static let live: GuidanceSessionFactory = { camera, method, options, onSample in
        LiveTrackingSource(camera: camera, panelTracker: panelTracker(for: method, options: options),
                           onSample: onSample)
    }

    static func panelTracker(for method: PanelTrackingMethod,
                             options: FeatureTrackingOptions) -> any PanelTracking {
        switch method {
        case .vision:
            return PanelTracker()
        case .features:
            return FeaturePanelTracker(options: options)
        case .hybrid:
            return HybridPanelTracker(visual: FeaturePanelTracker(options: options))
        }
    }

    /// Vision-only factory retained for explicitly limited/injected sessions.
    static let vision: GuidanceSessionFactory = { camera, method, _, onSample in
        guard method == .vision else { throw GuidanceSessionFactoryError.unimplemented(method) }
        return LiveTrackingSource(camera: camera, onSample: onSample)
    }
}
