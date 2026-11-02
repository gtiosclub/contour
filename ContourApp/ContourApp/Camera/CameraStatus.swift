import Foundation
import Observation

/// Main-actor presentation state, separate from capture's mutation queue.
@MainActor @Observable
final class CameraStatus {
    var error: String?
    /// The system took the camera away, e.g. in the background. Capture resumes
    /// by itself when it ends; `error` is for failures that need a retry.
    var isInterrupted = false
    var revision = 0
    private var captureGeneration: UUID?
    nonisolated init() {}

    /// Multiple consumers can start the same camera. Only a new capture run
    /// invalidates subscriptions; repeated starts must not trigger restart loops.
    func didStartRun(_ generation: UUID) {
        error = nil
        guard captureGeneration != generation else { return }
        captureGeneration = generation
        revision &+= 1
    }
}
