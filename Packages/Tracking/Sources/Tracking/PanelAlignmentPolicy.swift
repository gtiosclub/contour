/// Geometry policy consumes observations supplied by any visual implementation.
/// Flags describe the most recent update; they coordinate feature selection and
/// restoration without requiring geometry code to depend on OpenCV.
public protocol PanelAlignmentPolicy: Sendable {
    var isCalibrated: Bool { get }
    var acceptedCalibrationView: Bool { get }
    var didReset: Bool { get }
    var needsFeatureRestore: Bool { get }
    mutating func update(visual: PanelObservation, world: WorldCameraSnapshot?) -> PanelObservation
}
