#if DEBUG
import ContourCore
import ContourMocks
import SwiftUI
import Tracking

struct TrackingDebugView: View {
    let camera: CameraService
    let pipeline: ContourPipeline
    @State private var model = TrackingDebugModel()
    @State private var showOverlay = true
    @State private var showReferenceSetup = false
    @State private var showManualSetup = false
    @State private var manualPhoto: PanelPhoto?
    @State private var capture: Task<Void, Never>?
    @State private var capturing = false
    @State private var captureError: String?
    @State private var manualReference = ManualReferenceState()
    @Environment(\.scenePhase) private var scenePhase

    private struct RunID: Hashable { let reference: UUID?; let active: Bool }
    private var runID: RunID {
        RunID(reference: manualReference.reference?.photo.id, active: scenePhase == .active)
    }

    private var distanceToTarget: Double? {
        guard let frame = model.trackingFrame, frame.trackingQuality != .lost,
              let finger = frame.fingertip,
              let targetID = manualReference.selectedTargetID,
              let target = manualReference.reference?.detection.map.buttons.first(where: { $0.id == targetID })
        else { return nil }
        let distance = finger.distance(to: target.bounds.center)
        return distance.isFinite ? distance : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = model.image {
                    TrackingImageView(image: image,
                        quad: showOverlay ? model.panelQuad : nil,
                        fingertip: showOverlay ? model.latest?.fingertip : nil,
                        buttons: showOverlay ? manualReference.reference?.detection.map.buttons ?? [] : [],
                        targetID: manualReference.selectedTargetID)
                } else {
                    Rectangle().fill(.black).aspectRatio(9.0 / 16, contentMode: .fit)
                        .overlay { Text(model.error ?? "Waiting for camera frames…").foregroundStyle(.white).padding() }
                }
                Text("Yellow: panel. Green: fingertip. Cyan: buttons. Orange: selected target. Pixels and overlays come from the same processed frame.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show tracking overlay", isOn: $showOverlay)
                Button(capturing ? "Capturing…" : "Capture manual panel and target") { capturePanel() }
                    .buttonStyle(.borderedProminent).disabled(capturing)
                if let reference = manualReference.reference {
                    Text("Live panel + fingertip tracking")
                    Picker("Visual target", selection: Binding(
                        get: { manualReference.selectedTargetID },
                        set: { manualReference.selectTarget($0) }
                    )) {
                        Text("No target").tag(UUID?.none)
                        ForEach(reference.detection.map.buttons) { button in
                            Text(button.label ?? "Unlabelled").tag(Optional(button.id))
                        }
                    }
                    if let point = model.trackingFrame?.fingertip {
                        Text("Finger on panel: x \(point.x.formatted(.number.precision(.fractionLength(3)))), y \(point.y.formatted(.number.precision(.fractionLength(3))))")
                            .monospacedDigit()
                    }
                } else {
                    Text("Fingertip-only mode. Prepare a panel reference above to verify panel tracking and finger-to-panel mapping.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("2D distance to target center") {
                    if let distance = distanceToTarget {
                        Text("\(distance.formatted(.number.precision(.fractionLength(3)))) panel units")
                            .monospacedDigit()
                    } else {
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                }
                Text("0 means the target center. Each panel axis runs from 0 to 1. Requires a selected target and usable panel/finger tracking.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Visual samples", value: "\(model.framesProcessed)")
                Text(model.latest?.status.rawValue ?? (model.running ? "Waiting for frames" : "Camera stopped"))
                if let frame = model.trackingFrame {
                    LabeledContent("Tracking quality", value: frame.trackingQuality.rawValue.capitalized)
                    LabeledContent("Panel confidence", value: frame.panel.confidence.formatted(.percent))
                }
                if let assessment = model.assessment {
                    Text(assessment.reason.message).font(.caption).foregroundStyle(.secondary)
                }
                if let latency = model.latency {
                    LabeledContent("Capture-to-display age", value: "\(Int(latency * 1_000)) ms")
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if let captureError { Text(captureError).foregroundStyle(.red) }
                Text("Keep the phone upright. Move it slightly and check that the yellow outline stays on the panel. Remove your finger or hide the panel to verify missing results disappear.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced: supplied fixture layout") {
                    Button("Prepare six-button microwave fixture reference") { showReferenceSetup = true }
                    Text("Use only with a panel matching that supplied layout.").font(.caption)
                }
            }
            .padding()
        }
        .navigationTitle("Tracking Diagnostics")
        .sheet(isPresented: $showManualSetup) {
            NavigationStack {
                if let photo = manualPhoto {
                    ManualTrackingSetupView(photo: photo) { reference in
                        await use(reference)
                    }
                }
            }
        }
        .sheet(isPresented: $showReferenceSetup) {
            NavigationStack {
                ManualReferenceSetupView(layout: MockSurfaceMaps.microwave,
                    layoutName: "six-button microwave fixture") { reference in
                        Task { await use(reference) }
                    }
            }
        }
        .onAppear {
            if let reference = pipeline.panelReference, reference.detection.quad != .fullFrame {
                manualReference.replace(with: reference)
                manualReference.selectTarget(reference.detection.map.buttons.first?.id)
            }
        }
        .task(id: runID) {
            guard runID.active else { model.clearDisplayedResults(); return }
            await model.run(camera: camera, reference: manualReference.reference)
        }
        .onDisappear { capture?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { capture?.cancel() }
        }
    }

    private func use(_ reference: PanelReference) async {
        await pipeline.replaceReference(with: reference)
        guard !Task.isCancelled, pipeline.panelReference?.photo.id == reference.photo.id else { return }
        model.clearDisplayedResults()
        manualReference.replace(with: reference)
        manualReference.selectTarget(reference.detection.map.buttons.first?.id)
    }

    private func capturePanel() {
        capturing = true
        captureError = nil
        capture = Task {
            defer { capturing = false }
            do {
                let photo = try await camera.capturePanelPhoto()
                try Task.checkCancellation()
                manualPhoto = photo
                showManualSetup = true
            } catch is CancellationError {
            } catch {
                captureError = error.localizedDescription
            }
        }
    }
}
#endif
