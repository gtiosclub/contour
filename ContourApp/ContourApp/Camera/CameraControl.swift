import Tracking

/// Camera ownership remains with the app. UI work can inject controls and
/// frames without an ARSession or permission prompt in component tests.
nonisolated protocol CameraControl: CameraFrameSource {
    @MainActor var status: CameraStatus { get }
    var usesWorldTracking: Bool { get }
    func start() async throws
    func stop() async
    @MainActor func retry() async
    func setExposureBias(_ value: Float) async throws -> Float?
}
