#if DEBUG
import ContourCore
import ContourMocks
import SwiftUI
import Tracking

struct TrackingDebugView: View {
    let camera: CameraService
    @State private var model = TrackingDebugModel()
    @State private var showOverlay = true
    @State private var showReferenceSetup = false
    @State private var preparedReference: PanelReference?
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
            Button("Prepare manual panel reference") { showReferenceSetup = true }
                .buttonStyle(.bordered)
            if let preparedReference {
                Text("Reference prepared: \(preparedReference.detection.map.buttons.count) buttons. "
                     + "Live initialization waits for the tracker and pipeline reset interfaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        .sheet(isPresented: $showReferenceSetup) {
            NavigationStack {
                ManualReferenceSetupView(layout: MockSurfaceMaps.microwave,
                                         layoutName: "six-button microwave fixture") { reference in
                    preparedReference = reference
                }
            }
        }
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
