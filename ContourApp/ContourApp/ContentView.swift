import SwiftUI

/// Owns the shared camera lifetime, including the DEBUG tools' subscriptions.
struct ContentView: View {
    let pipeline: ContourPipeline
    let camera: CameraService
    @State private var experience: CameraLaunchModel
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var showDeveloperTools = false
    #endif

    init(pipeline: ContourPipeline, camera: CameraService) {
        self.pipeline = pipeline
        self.camera = camera
        _experience = State(initialValue: CameraLaunchModel(camera: camera, pipeline: pipeline))
    }

    var body: some View {
        NavigationStack {
            LiveCameraView(camera: camera, pipeline: pipeline, experience: experience)
                .navigationTitle("Contour")
                .navigationBarTitleDisplayMode(.inline)
                #if DEBUG
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Developer tools", systemImage: "wrench.and.screwdriver") {
                            Task {
                                experience.stop()
                                await experience.waitForWork()
                                showDeveloperTools = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $showDeveloperTools) {
                    NavigationStack { DebugMenu(camera: camera, pipeline: pipeline) }
                }
                #endif
        }
        .onAppear { experience.setActive(scenePhase == .active) }
        .onDisappear { experience.setActive(false) }
        .onChange(of: scenePhase) { _, phase in experience.setActive(phase == .active) }
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
