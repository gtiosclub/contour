//
//  ManualTrackingTestView.swift
//  ContourApp — Debug
//
//  The scaffold home screen's "Manual tracking test", moved here intact:
//  capture a frame from the shared camera, mark the panel's corners and a
//  target by hand (bypassing Surface), then run real tracking and guidance to
//  that target. A manual reference prepared in Tracking Diagnostics works too.
//

#if DEBUG
import ContourCore
import SwiftUI

struct ManualTrackingTestView: View {
    let pipeline: ContourPipeline
    let camera: CameraService

    @State private var photo: PanelPhoto?
    @State private var showSetup = false
    @State private var captureTask: Task<Void, Never>?
    @State private var captureID: UUID?
    @State private var guidanceTask: Task<Void, Never>?
    @State private var guidanceID: UUID?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    /// The manual target, if the pipeline's reference is a manual one.
    private var target: SurfaceMap.Button? {
        guard let map = pipeline.panelReference?.detection.map,
              map.buttons.count == 1, map.buttons.first?.label == "Manual target" else { return nil }
        return map.buttons.first
    }

    var body: some View {
        List {
            Section {
                CameraPreview(session: camera.session)
                    .frame(height: 360)
                    .listRowInsets(EdgeInsets())
                    .task { try? await camera.start() }
            } footer: {
                Text("Aim at the panel. The capture is the exact frame Tracking will follow.")
            }

            Section {
                if !pipeline.liveComponents.contains(.tracking) {
                    Text("Tracking is mocked in this build, so this test has nothing to measure. Run on a phone.")
                        .foregroundStyle(.secondary)
                }
                Button(captureTask == nil ? "Capture panel and mark target" : "Capturing…") { capture() }
                    .disabled(captureTask != nil || !pipeline.liveComponents.contains(.tracking))
                Button(guidanceTask == nil ? "Guide to manual target" : "Stop") { toggleGuidance() }
                    .disabled(target == nil || !pipeline.canGuide || captureTask != nil)
            } footer: {
                Text("Bypasses Surface detection: you mark the panel's corners and the target. Tracking and vibration stay live.")
            }

            if error != nil || pipeline.trackingError != nil || pipeline.latestGuidance != nil {
                Section("Status") {
                    if let error { Text(error).foregroundStyle(.red) }
                    if let trackingError = pipeline.trackingError { Text(trackingError).foregroundStyle(.red) }
                    if let vector = pipeline.latestGuidance?.vector {
                        LabeledContent("Distance to target",
                                       value: vector.normalizedDistance.formatted(.number.precision(.fractionLength(3))))
                    }
                    if let outcome = pipeline.latestGuidance?.outcome {
                        LabeledContent("Outcome", value: outcome.rawValue)
                    }
                }
            }
        }
        .navigationTitle("Manual Tracking Test")
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                if let photo {
                    ManualTrackingSetupView(photo: photo) { reference in
                        await pipeline.replaceReference(with: reference)
                        guard pipeline.panelReference?.photo.id == reference.photo.id,
                              !Task.isCancelled else { throw CancellationError() }
                        error = nil
                    }
                }
            }
        }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop() }
        }
    }

    private func capture() {
        stop()
        error = nil
        let id = UUID()
        captureID = id
        captureTask = Task {
            defer { if captureID == id { captureTask = nil } }
            do {
                await pipeline.stopGuidance()
                try Task.checkCancellation()
                let captured = try await camera.capturePanelPhoto()
                guard captureID == id, !Task.isCancelled else { return }
                photo = captured
                showSetup = true
            } catch is CancellationError {
            } catch {
                if captureID == id { self.error = error.localizedDescription }
            }
        }
    }

    private func toggleGuidance() {
        if guidanceTask != nil {
            stop()
            return
        }
        guard pipeline.canGuide, let target else {
            error = "Prepare a manual reference first."
            return
        }
        let id = UUID()
        guidanceID = id
        guidanceTask = Task {
            await pipeline.guide(to: target)
            if guidanceID == id {
                guidanceTask = nil
                guidanceID = nil
            }
        }
    }

    private func stop() {
        captureTask?.cancel()
        captureTask = nil
        captureID = nil
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
    }
}
#endif
