#if DEBUG
import ContourCore
import SwiftUI

/// Shares the app-owned camera. Diagnostics own subscriptions, not its lifetime.
struct DebugMenu: View {
    let camera: CameraService
    let pipeline: ContourPipeline
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: PanelPhoto?
    @State private var capture: Task<Void, Never>?
    @State private var error: String?
    @State private var capturing = false
    @State private var showManual = false

    var body: some View {
        List {
            Section("Diagnostics") {
                NavigationLink("Tracking Diagnostics") { TrackingDebugView(camera: camera, pipeline: pipeline) }
                NavigationLink("Model image spike (Surface)") { ModelImageSpikeView() }
                NavigationLink("Haptics") { HapticsDebugView() }
                NavigationLink("Anushka's Debug Tool") { AnushkaDebugView() }
                Button(capturing ? "Capturing…" : "Manual tracking test") {
                    capturing = true
                    capture = Task {
                        defer { capturing = false }
                        do {
                            photo = try await camera.capturePanelPhoto()
                            try Task.checkCancellation()
                            showManual = true
                        } catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(capturing)
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("Pipeline") {
                ForEach(ContourPipeline.Component.allCases, id: \.self) { component in
                    LabeledContent(component.rawValue,
                                   value: pipeline.liveComponents.contains(component) ? "live" : "mocked")
                }
            }
            if let reference = pipeline.panelReference, !reference.photo.data.isEmpty {
                Section("Captured image and returned controls") {
                    CapturedPanelReviewView(reference: reference)
                }
            }
        }
        .navigationTitle("Developer tools")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showManual) {
            NavigationStack {
                if let photo {
                    ManualTrackingSetupView(photo: photo) { reference in
                        await pipeline.replaceReference(with: reference)
                        try Task.checkCancellation()
                        guard pipeline.panelReference?.photo.id == reference.photo.id else { throw CancellationError() }
                    }
                }
            }
        }
        .onDisappear { capture?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { capture?.cancel() }
        }
    }
}
#endif
