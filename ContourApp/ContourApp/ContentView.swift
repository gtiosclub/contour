import AVFoundation
import ContourFeedback
import SwiftUI
import UIKit

/// Owns the shared camera lifetime, including the DEBUG tools' subscriptions.
struct ContentView: View {
    let pipeline: ContourPipeline
    let camera: CameraService
    @AppStorage(FeedbackPreferenceKeys.audio) private var audioEnabled = true
    @AppStorage(FeedbackPreferenceKeys.voice) private var voiceEnabled = true
    @AppStorage(FeedbackPreferenceKeys.haptics) private var hapticsEnabled = true
    @AppStorage(FeedbackPreferenceKeys.intensity) private var hapticIntensity = 0.85
    @State private var experience: CameraLaunchModel
    /// Whether this screen last started the camera, as `AppLifecycle` decides.
    @State private var running = false
    @Environment(\.scenePhase) private var scenePhase

    init(pipeline: ContourPipeline, camera: CameraService) {
        self.pipeline = pipeline
        self.camera = camera
        _experience = State(initialValue: CameraLaunchModel(camera: camera, pipeline: pipeline,
                                                            openAI: OpenAIPlans.fromBundle()))
    }

    var body: some View {
        LiveCameraView(camera: camera, pipeline: pipeline, experience: experience)
            .onAppear { applyFeedbackSettings(); run(AppLifecycle.runs(in: scenePhase, wasRunning: false)) }
            .onDisappear { run(false) }
            .onChange(of: scenePhase) { _, phase in run(AppLifecycle.runs(in: phase, wasRunning: running)) }
            .onChange(of: audioEnabled) { _, _ in applyFeedbackSettings() }
            .onChange(of: voiceEnabled) { _, _ in applyFeedbackSettings() }
            .onChange(of: hapticsEnabled) { _, _ in applyFeedbackSettings() }
            .onChange(of: hapticIntensity) { _, _ in applyFeedbackSettings() }
            // Only audio taken by a call or Siri stops the request. A camera
            // interruption doesn't: tracking keeps its streams and starts over when
            // ARKit comes back, so a plan can carry on.
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if AppLifecycle.audioWasTaken(notification.userInfo) { experience.stop() }
            }
    }

    /// The screen stays on while the camera runs: a 5-key plan with a minute for
    /// each "next" outlasts Auto-Lock, and locking ends the plan.
    private func run(_ value: Bool) {
        guard value != running else { return }
        running = value
        UIApplication.shared.isIdleTimerDisabled = value
        experience.setActive(value)
    }

    private func applyFeedbackSettings() {
        (pipeline.feedback as? LiveFeedbackEngine)?.setChannels(audio: audioEnabled, voice: voiceEnabled,
            haptics: hapticsEnabled, intensity: hapticIntensity)
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
