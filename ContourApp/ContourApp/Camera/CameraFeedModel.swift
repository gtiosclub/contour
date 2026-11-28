import ContourCore
import CoreGraphics
import Foundation
import Observation
import Tracking

/// A detected target in the coordinate space of the exact image that was tracked.
struct GuidanceTargetFrame {
    struct Marker {
        let sessionID: UInt64
        let corners: [ImagePoint]
        let title: String
    }

    let cameraFrame: CameraFrame
    let marker: Marker

    init?(sample: LiveTrackingSample, target: SurfaceMap.Button, sessionID: UInt64) {
        let bounds = target.bounds
        guard sample.frame.trackingQuality != .lost, let quad = sample.panelQuad,
              bounds.width > 0, bounds.height > 0,
              let projection = try? PanelHomography(quad: quad) else { return nil }
        let panelCorners = [
            bounds.origin,
            PanelPoint(x: bounds.maxX, y: bounds.minY),
            PanelPoint(x: bounds.maxX, y: bounds.maxY),
            PanelPoint(x: bounds.minX, y: bounds.maxY),
        ]
        let corners = panelCorners.compactMap { projection.imagePoint(for: $0) }
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        cameraFrame = sample.cameraFrame
        let name = target.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        marker = Marker(sessionID: sessionID, corners: corners,
                        title: name.isEmpty ? "Unlabelled button" : name)
    }
}

/// One preview subscription per camera run. When the stream finishes, the run
/// is over, so its last image is cleared rather than left looking live.
@MainActor @Observable
final class CameraFeedModel {
    struct Preview {
        let image: CGImage
        let marker: GuidanceTargetFrame.Marker?
    }

    private(set) var preview: Preview?
    var image: CGImage? { preview?.image }
    @ObservationIgnored private let renderer = FrameImageRenderer()
    @ObservationIgnored private var currentRun: UUID?

    func run(camera: any CameraFrameSource, framesPerSecond: Double,
             targetFrame: @MainActor () -> GuidanceTargetFrame? = { nil }) async {
        let run = UUID()
        currentRun = run
        preview = nil
        // A cancelled older run can finish after a newer one has drawn; it
        // must not wipe or overwrite the newer run's image.
        defer { if currentRun == run { preview = nil } }
        let clock = ContinuousClock()
        let interval = Duration.seconds(1 / framesPerSecond)
        for await frame in await camera.cameraFrames() {
            let started = clock.now
            // Show an outline only on its own tracked pixels. If tracking falls
            // behind the camera, use the latest ordinary preview frame again.
            let tracked = targetFrame().flatMap { tracked in
                abs(frame.timestamp.timeIntervalSince(tracked.cameraFrame.timestamp)) <= 0.25 ? tracked : nil
            }
            let rendered = await renderer.previewImage(for: tracked?.cameraFrame ?? frame)
            guard !Task.isCancelled, currentRun == run else { return }
            if let rendered {
                preview = Preview(image: rendered, marker: tracked?.marker)
            }
            do { try await clock.sleep(until: started + interval) } catch { return }
        }
    }
}
