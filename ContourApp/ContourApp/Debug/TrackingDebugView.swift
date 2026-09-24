#if DEBUG
import SwiftUI
import Tracking

struct TrackingDebugView: View {
    let camera: CameraService
    @State private var model = TrackingDebugModel()
    @State private var showOverlay = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 12) {
            CameraPreview(session: camera.session,
                          fingertip: showOverlay ? model.latest?.fingertip : nil)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text("Fixed portrait camera basis")
                        .font(.caption).padding(8).background(.regularMaterial)
                }
            Toggle("Show tracking overlay", isOn: $showOverlay)
            LabeledContent("Frames processed", value: "\(model.framesProcessed)")
            Text(model.latest?.status.rawValue ?? (model.running ? "Waiting for frames" : "Camera stopped"))
            if let confidence = model.latest?.confidence {
                LabeledContent("Confidence", value: confidence.formatted(.percent))
            }
            if let assessment = model.assessment {
                LabeledContent("Tracking quality", value: assessment.qualityLabel)
                Text(assessment.reason.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Text("Scaffolding only: finger detection and panel tracking are team tasks. No landmarks are generated yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Tracking Diagnostics")
        .task {
            await model.run(camera: camera)
        }
        .onChange(of: scenePhase) { _, phase in
            // End this session when backgrounded. Reopen the screen to restart.
            if phase != .active { Task { await camera.stop() } }
        }
    }
}
#endif
