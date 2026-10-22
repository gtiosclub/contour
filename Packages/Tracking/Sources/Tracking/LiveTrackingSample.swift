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
    public let panelStatus: PanelObservation.Status?
    public let featureDiagnostics: FeatureTrackingDiagnostics?
    public let hybridDiagnostics: HybridTrackingDiagnostics?

    public init(
        cameraFrame: CameraFrame,
        frame: TrackingFrame,
        panelQuad: PanelQuad? = nil,
        imageFingertip: ImagePoint? = nil,
        assessment: TrackingAssessment? = nil,
        registrationError: PanelTrackingError? = nil,
        panelStatus: PanelObservation.Status? = nil,
        featureDiagnostics: FeatureTrackingDiagnostics? = nil,
        hybridDiagnostics: HybridTrackingDiagnostics? = nil
    ) {
        self.cameraFrame = cameraFrame
        self.frame = frame
        self.panelQuad = panelQuad
        self.imageFingertip = imageFingertip
        self.assessment = assessment
        self.registrationError = registrationError
        self.panelStatus = panelStatus
        self.featureDiagnostics = featureDiagnostics
        self.hybridDiagnostics = hybridDiagnostics
    }
}
