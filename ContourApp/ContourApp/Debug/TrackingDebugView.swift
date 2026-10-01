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
    @State private var manualReference = ManualReferenceState()
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
            Button(manualReference.reference == nil
                   ? "Prepare manual panel reference" : "Replace manual panel reference") {
                showReferenceSetup = true
            }
                .buttonStyle(.bordered)
            if let reference = manualReference.reference {
                Text("Reference prepared: \(reference.detection.map.buttons.count) buttons. "
                     + "Live initialization waits for the tracker and pipeline reset interfaces.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Debug target", selection: Binding(
                    get: { manualReference.selectedTargetID },
                    set: { manualReference.selectTarget($0) }
                )) {
                    Text("No target").tag(UUID?.none)
                    ForEach(reference.detection.map.buttons) { button in
                        Text(button.label ?? "Unlabelled button")
                            .tag(Optional(button.id))
                    }
                }
            }
            LabeledContent("Frames processed", value: "\(model.framesProcessed)")
            Text(model.latest?.status.rawValue ?? (model.running ? "Waiting for frames" : "Camera stopped"))
            if let confidence = model.latest?.confidence {
                LabeledContent("Confidence", value: confidence.formatted(.percent))
            }
            if let assessment = model.assessment {
                LabeledContent("Tracking quality", value: assessment.qualityLabel)
                Text(assessment.reason == .tracking ? "Fingertip tracked" : assessment.reason.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Text("Point one index finger at the rear camera. The dot shows image-space detection; panel tracking is separate. Keep the phone upright.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Tracking Diagnostics")
        .sheet(isPresented: $showReferenceSetup) {
            NavigationStack {
                ManualReferenceSetupView(layout: MockSurfaceMaps.microwave,
                                         layoutName: "six-button microwave fixture") { reference in
                    model.clearDisplayedResults()
                    manualReference.replace(with: reference)
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
