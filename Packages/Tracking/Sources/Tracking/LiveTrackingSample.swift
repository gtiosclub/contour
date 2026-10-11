import ContourCore
import Foundation

/// Diagnostics for the exact camera frame used by the production fusion path.
/// Image coordinates stay separate from the emitted panel-space fingertip.
public struct LiveTrackingSample: Sendable {
    public let cameraFrame: CameraFrame
    public let frame: TrackingFrame
    public let panelQuad: PanelQuad?
    public let imageFingertip: ImagePoint?
    public let assessment: TrackingAssessment?
    public let registrationError: PanelTrackingError?
}
