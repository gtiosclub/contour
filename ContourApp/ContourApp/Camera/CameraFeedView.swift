import CoreGraphics
import SwiftUI
import Tracking

/// The live camera drawn from the shared frame stream, so it works whichever
/// capture path is running and shows the same field of view the photo keeps.
///
/// Frames are rotated upright and scaled down off the UI actor, at most
/// `framesPerSecond` times a second. The stream keeps only the newest frame, so
/// a slow render skips frames instead of falling behind. Tracking and photo
/// capture subscribe separately and still receive full-size frames.
struct CameraFeedView: View {
    let camera: any CameraFrameSource
    var framesPerSecond: Double = 15
    @State private var image: CGImage?
    private let renderer = FrameImageRenderer()

    var body: some View {
        ZStack {
            Color.black
            if let image {
                // Aspect fit: the whole frame, with black bars rather than a crop.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rear camera preview")
        .task {
            let clock = ContinuousClock()
            let interval = Duration.seconds(1 / framesPerSecond)
            for await frame in await camera.cameraFrames() {
                let started = clock.now
                let rendered = await renderer.previewImage(for: frame)
                guard !Task.isCancelled else { return }
                if let rendered { image = rendered }
                do { try await clock.sleep(until: started + interval) } catch { return }
            }
        }
    }
}
