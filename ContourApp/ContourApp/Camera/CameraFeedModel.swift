import CoreGraphics
import Foundation
import Observation
import Tracking

/// One preview subscription per camera run. When the stream finishes, the run
/// is over, so its last image is cleared rather than left looking live.
@MainActor @Observable
final class CameraFeedModel {
    private(set) var image: CGImage?
    @ObservationIgnored private let renderer = FrameImageRenderer()
    @ObservationIgnored private var currentRun: UUID?

    func run(camera: any CameraFrameSource, framesPerSecond: Double) async {
        let run = UUID()
        currentRun = run
        image = nil
        // A cancelled older run can finish after a newer one has drawn; it
        // must not wipe or overwrite the newer run's image.
        defer { if currentRun == run { image = nil } }
        let clock = ContinuousClock()
        let interval = Duration.seconds(1 / framesPerSecond)
        for await frame in await camera.cameraFrames() {
            let started = clock.now
            let rendered = await renderer.previewImage(for: frame)
            guard !Task.isCancelled, currentRun == run else { return }
            if let rendered { image = rendered }
            do { try await clock.sleep(until: started + interval) } catch { return }
        }
    }
}
