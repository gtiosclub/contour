import ContourCore

/// Panel alignment engines consume sequential immutable frames. A replacement
/// reference or stop must supersede in-flight work; lost output carries no quad.
public protocol PanelTracking: Sendable {
    func startTracking(_ reference: PanelReference) async throws
    func track(_ frame: CameraFrame) async throws -> PanelObservation
    func stopTracking() async
}

extension PanelTracker: PanelTracking {}

/// Feature-selection hooks coordinated by the hybrid actor, not by the camera.
public protocol CalibratablePanelTracking: PanelTracking {
    func observeCalibrationView() async
    func finishCalibration() async -> Int?
    func resetCalibration() async
}

/// Names only. Feature/hybrid implementations and their factory belong to later
/// tasks; S0 never silently substitutes Vision for an unimplemented method.
public enum PanelTrackingMethod: String, CaseIterable, Hashable, Sendable {
    case vision = "Vision rectangle (comparison)"
    case features = "OpenCV surface features"
    case hybrid = "Hybrid surface + world tracking"
}

public struct FeatureTrackingOptions: Hashable, Sendable {
    public var excludeHighlights: Bool
    public var normalizeContrast: Bool

    public init(excludeHighlights: Bool = true, normalizeContrast: Bool = false) {
        self.excludeHighlights = excludeHighlights
        self.normalizeContrast = normalizeContrast
    }
}
