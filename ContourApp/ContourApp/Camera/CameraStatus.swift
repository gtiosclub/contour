import Observation

/// Main-actor presentation state, separate from capture's mutation queue.
@MainActor @Observable
final class CameraStatus {
    var error: String?
    var revision = 0
    nonisolated init() {}
}
