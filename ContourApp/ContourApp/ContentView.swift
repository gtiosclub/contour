import AVFoundation
import ContourFeedback
import SwiftUI

/// Owns the shared camera lifetime, including the DEBUG tools' subscriptions.
struct ContentView: View {
    let pipeline: ContourPipeline
    let camera: CameraService
    @AppStorage(FeedbackPreferenceKeys.audio) private var audioEnabled = true
    @AppStorage(FeedbackPreferenceKeys.voice) private var voiceEnabled = true
    @AppStorage(FeedbackPreferenceKeys.haptics) private var hapticsEnabled = true
    @AppStorage(FeedbackPreferenceKeys.intensity) private var hapticIntensity = 0.85
    @State private var experience: CameraLaunchModel
    @Environment(\.scenePhase) private var scenePhase

    init(pipeline: ContourPipeline, camera: CameraService) {
        self.pipeline = pipeline
        self.camera = camera
        _experience = State(initialValue: CameraLaunchModel(camera: camera, pipeline: pipeline))
    }

    var body: some View {
        LiveCameraView(camera: camera, pipeline: pipeline, experience: experience)
            .onAppear { applyFeedbackSettings(); experience.setActive(scenePhase == .active) }
            .onDisappear { experience.setActive(false) }
            .onChange(of: scenePhase) { _, phase in experience.setActive(phase == .active) }
            .onChange(of: audioEnabled) { _, _ in applyFeedbackSettings() }
            .onChange(of: voiceEnabled) { _, _ in applyFeedbackSettings() }
            .onChange(of: hapticsEnabled) { _, _ in applyFeedbackSettings() }
            .onChange(of: hapticIntensity) { _, _ in applyFeedbackSettings() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
                experience.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: reason) == .oldDeviceUnavailable else { return }
                experience.stop()
            }
            .onChange(of: camera.status.isInterrupted) { _, interrupted in
                if interrupted { experience.stop() }
            }
    }

    private func applyFeedbackSettings() {
        (pipeline.feedback as? LiveFeedbackEngine)?.setChannels(audio: audioEnabled, voice: voiceEnabled,
            haptics: hapticsEnabled, intensity: hapticIntensity)
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
