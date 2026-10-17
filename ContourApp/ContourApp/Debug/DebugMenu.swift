//
//  DebugMenu.swift
//  ContourApp — Debug
//
//  Every developer screen, in one list, named for what it does. DEBUG builds
//  only; reached from the ladybug button on the main screen. Add one line per
//  new screen — and name it after the job, not the person who wrote it.
//
//  While this menu is open the main flow stands down (ExperienceModel
//  .pauseForDebugTools), so these tools have the pipeline and camera to
//  themselves. Closing it returns the app to the camera.
//

#if DEBUG
import ContourFeedback
import SwiftUI

struct DebugMenu: View {
    let pipeline: ContourPipeline
    let camera: CameraService

    var body: some View {
        List {
            Section("Pipeline") {
                NavigationLink("Pipeline Status") { PipelineStatusView(pipeline: pipeline) }
                NavigationLink("Captured Panel Review") { CapturedPanelReviewScreen(pipeline: pipeline) }
            }
            Section("Tracking") {
                NavigationLink("Tracking Diagnostics") { TrackingDebugView(camera: camera, pipeline: pipeline) }
                NavigationLink("Manual Tracking Test") { ManualTrackingTestView(pipeline: pipeline, camera: camera) }
            }
            Section("Feedback") {
                NavigationLink("Haptics") { HapticsDebugView() }
                NavigationLink("Directional Audio") { AudioDebugView() }
                NavigationLink("Speech Queue") { SpeechDebugView(queue: SpeechQueue()) }
            }
            Section("Surface Understanding") {
                NavigationLink("Model Image Spike (Surface)") { ModelImageSpikeView() }
            }
            Section("Prototypes") {
                NavigationLink("Camera & Speech Prototype") { LiveCameraView() }
            }
        }
        .navigationTitle("Debug Menu")
    }
}
#endif
