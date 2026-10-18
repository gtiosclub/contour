import SwiftUI

/// Owns the shared camera lifetime, including the DEBUG tools' subscriptions.
struct ContentView: View {
    let pipeline: ContourPipeline
    let camera: CameraService
    @State private var experience: CameraLaunchModel
    @Environment(\.scenePhase) private var scenePhase

    init(pipeline: ContourPipeline, camera: CameraService) {
        self.pipeline = pipeline
        self.camera = camera
        _experience = State(initialValue: CameraLaunchModel(camera: camera, pipeline: pipeline))
    }

    var body: some View {
        LiveCameraView(camera: camera, pipeline: pipeline, experience: experience)
            .onAppear { experience.setActive(scenePhase == .active) }
            .onDisappear { experience.setActive(false) }
            .onChange(of: scenePhase) { _, phase in experience.setActive(phase == .active) }
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
