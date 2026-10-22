import Observation

/// Main-actor presentation state, separate from capture's mutation queue.
@MainActor @Observable
final class CameraStatus {
    var error: String?
    /// The system took the camera away, e.g. in the background. Capture resumes
    /// by itself when it ends; `error` is for failures that need a retry.
    var isInterrupted = false
    var revision = 0
    nonisolated init() {}
}
