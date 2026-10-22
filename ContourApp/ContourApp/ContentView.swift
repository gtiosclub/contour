//
//  ContentView.swift
//  ContourApp — Experience / Accessibility & Launch
//
//  Scaffolding placeholder. Experience replaces this with the real camera
//  experience — ContourUI.ContourCameraView is where that starts.
//
//  It shows which packages are live and which are still mocked, and runs the
//  mock pipeline end to end so that a fresh clone demonstrably works on device.
//

import ContourCore
import ContourMocks
import ContourUI
import SwiftUI

struct ContentView: View {

    let pipeline: ContourPipeline
    /// Shared with the pipeline, so live tracking follows the camera you aim.
    let camera: CameraService

    @State private var map: SurfaceMap?
    @State private var lastError: String?
    @State private var guidanceTask: Task<Void, Never>?
    @State private var guidanceID: UUID?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanID: UUID?
    @State private var listenTask: Task<Void, Never>?
    @State private var listenID: UUID?
    @State private var heard: String?
    #if DEBUG
    @State private var showManualTracking = false
    @State private var manualPhoto: PanelPhoto?
    @State private var manualTargetID: UUID?
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                Section("Developer tools") {
                    NavigationLink("Tracking Diagnostics") {
                        TrackingDebugView(camera: camera, pipeline: pipeline)
                    }
                    NavigationLink("Tracking status scenarios") { GuidanceStatusScenariosView() }
                    NavigationLink("Model image spike (Surface)") {
                        ModelImageSpikeView()
                    }
                    NavigationLink("Haptics") {
                        HapticsDebugView()
                    }
                }
                #endif

                
                #if DEBUG
                Section("Experience prototype") {
                    NavigationLink("Camera and speech prototype") {
                        LiveCameraView()
                    }
                    Text("Evan's separate UI and speech prototype. Use the pipeline controls below for integrated tracking and guidance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
                
                
                Section("Pipeline") {
                    ForEach(ContourPipeline.Component.allCases, id: \.self) { component in
                        LabeledContent(component.rawValue) {
                            Text(pipeline.liveComponents.contains(component) ? "live" : "mocked")
                                .foregroundStyle(
                                    pipeline.liveComponents.contains(component) ? .green : .secondary
                                )
                        }
                        .accessibilityLabel(
                            "\(component.rawValue), owned by \(component.team), "
                            + (pipeline.liveComponents.contains(component) ? "live" : "mocked")
                        )
                    }
                }

                Section("Detected panel") {
                    if let map {
                        LabeledContent(
                            "Panel confidence",
                            value: map.confidence.formatted(.number.precision(.fractionLength(2)))
                        )
                        ForEach(map.buttons) { button in
                            LabeledContent(button.label ?? "Unlabelled") {
                                Text(button.confidence.formatted(.number.precision(.fractionLength(2))))
                                    .monospacedDigit()
                            }
                        }
                    } else {
                        Text("Not scanned yet.").foregroundStyle(.secondary)
                    }

                    if let lastError {
                        Text(lastError).foregroundStyle(.red)
                    }
                }

                if let reference = pipeline.panelReference, !reference.photo.data.isEmpty {
                    Section("Captured image and returned controls") {
                        DisclosureGroup("Review exact capture") {
                            CapturedPanelReviewView(reference: reference)
                        }
                    }
                }

                Section("Run the pipeline") {
                    if surfaceIsLive {
                        // What the scan will capture, so you can aim at the panel.
                        CameraPreview(session: camera.session)
                            .frame(height: 360)
                            .task { try? await camera.start() }
                    }
                    GuidanceStatusRow(snapshot: pipeline.guidanceStatus.current)
                        .task { await pipeline.guidanceStatus.run() }
                    Button("Scan panel") { scan() }
                    #if DEBUG
                    if pipeline.liveComponents.contains(.tracking) {
                        Button("Manual tracking test") { captureManualReference() }
                            .disabled(scanTask != nil)
                    }
                    #endif
                    Button(guidanceTask == nil ? guidanceTitle : "Stop") { toggleGuidance() }
                        .disabled(guidanceTask == nil && (map == nil || !pipeline.canGuide || scanTask != nil))
                    Button(listenTask == nil ? "Say a button" : "Listening…") { sayAButton() }
                        .disabled(map == nil || !pipeline.canGuide || scanTask != nil
                                  || listenTask != nil || guidanceTask != nil)
                    if let heard {
                        Text(heard).foregroundStyle(.secondary)
                    }
                    Text(pipeline.liveComponents.contains(.tracking)
                         ? "Keep the panel in view and move your finger toward the selected target. "
                           + "It vibrates faster as you get closer."
                         : pipeline.liveComponents.contains(.feedback)
                         ? "Guidance vibrates. Tracking is still simulated, so the "
                           + "phone acts out a finger moving to Start."
                         : "Guidance output goes to the console. Experience's rig "
                           + "is the Harness scheme on macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Experience — ContourUI") {
                    ContourCameraView()
                    if let map {
                        TargetSelectionView(map: map)
                    }
                }
            }
            .navigationTitle("Contour")
        }
        #if DEBUG
        .sheet(isPresented: $showManualTracking) {
            NavigationStack {
                if let photo = manualPhoto {
                    ManualTrackingSetupView(photo: photo) { reference in
                        await pipeline.replaceReference(with: reference)
                        guard pipeline.panelReference?.photo.id == reference.photo.id,
                              !Task.isCancelled else { throw CancellationError() }
                        manualTargetID = reference.detection.map.buttons.first?.id
                        map = reference.detection.map
                        lastError = nil
                    }
                }
            }
        }
        #endif
        .onChange(of: pipeline.panelReference?.photo.id) { _, _ in
            map = pipeline.panelReference?.detection.map
            #if DEBUG
            // Diagnostics can prepare a new manual target too. Never retain
            // the previous reference's button ID when returning to this screen.
            manualTargetID = map?.buttons.count == 1 && map?.buttons.first?.label == "Manual target"
                ? map?.buttons.first?.id : nil
            #endif
        }
        .onDisappear { stopWork() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopWork()
                Task { await camera.stop() }
            } else if surfaceIsLive {
                Task { try? await camera.start() }
            }
        }
    }

    private func scan() {
        #if DEBUG
        manualTargetID = nil
        #endif
        scanTask?.cancel()
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
        listenTask?.cancel()
        listenTask = nil
        listenID = nil
        map = nil
        lastError = nil
        let id = UUID()
        scanID = id
        scanTask = Task {
            defer { if scanID == id { scanTask = nil } }
            do {
                await pipeline.stopGuidance()
                try Task.checkCancellation()
                let photo = try await photoToScan()
                let detected = try await pipeline.detectPanel(in: photo)
                guard scanID == id, !Task.isCancelled else { return }
                map = detected
                if !pipeline.canGuide {
                    #if DEBUG
                    lastError = "Surface did not return a trackable panel outline. Try showing the full panel, or use Manual tracking test to test tracking independently."
                    #else
                    lastError = "Surface did not return a trackable panel outline. Try showing the full panel, then scan again."
                    #endif
                }
            } catch is CancellationError {
                // A replacement scan or navigation ended this request.
            } catch {
                if scanID == id { lastError = String(describing: error) }
            }
        }
    }

    private var guidanceTitle: String {
        #if DEBUG
        if manualTargetID != nil { return "Guide to manual target" }
        #endif
        return "Guide to Start"
    }

    #if DEBUG
    private func captureManualReference() {
        scanTask?.cancel()
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
        listenTask?.cancel()
        listenTask = nil
        listenID = nil
        lastError = nil
        let id = UUID()
        scanID = id
        scanTask = Task {
            defer { if scanID == id { scanTask = nil } }
            do {
                await pipeline.stopGuidance()
                try Task.checkCancellation()
                let photo = try await camera.capturePanelPhoto()
                guard scanID == id, !Task.isCancelled else { return }
                manualPhoto = photo
                showManualTracking = true
            } catch is CancellationError {
            } catch {
                if scanID == id { lastError = error.localizedDescription }
            }
        }
    }
    #endif

    private func stopWork() {
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
        listenTask?.cancel()
        listenTask = nil
        listenID = nil
        Task { await pipeline.stopGuidance() }
    }

    private var surfaceIsLive: Bool {
        pipeline.liveComponents.contains(.surfaceUnderstanding)
    }

    /// A frame from the camera when Surface Understanding is live. The mock
    /// ignores the photo entirely, so it gets a zero-byte one. Experience
    /// replaces this with a real capture from CaptureFlow.
    private func photoToScan() async throws -> PanelPhoto {
        if surfaceIsLive {
            return try await camera.capturePanelPhoto()
        }
        return PanelPhoto(data: Data(), pixelSize: PixelSize(width: 4032, height: 3024), timestamp: Date())
    }

    private func toggleGuidance() {
        if let guidanceTask {
            guidanceTask.cancel()
            pipeline.guidanceStatus.reset(to: .stopped)
            self.guidanceTask = nil
            guidanceID = nil
            return
        }
        guard pipeline.canGuide, let map, let target = guidanceTarget(in: map) else {
            lastError = "No Start button found on the panel."
            return
        }
        startGuidance(to: target)
    }

    /// Guide to Start and Say a button both start guidance here. Any guidance
    /// still running is cancelled, and the pipeline waits for it to end before
    /// the new one begins.
    private func startGuidance(to target: SurfaceMap.Button) {
        guidanceTask?.cancel()
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

    private func guidanceTarget(in map: SurfaceMap) -> SurfaceMap.Button? {
        #if DEBUG
        if let manualTargetID { return map.buttons.first { $0.id == manualTargetID } }
        #endif
        return ButtonLookup.button(for: "start", in: map)
    }

    /// Listen for a button's name, then guide to it the way Guide to Start does.
    private func sayAButton() {
        guard let map else { return }
        lastError = nil
        heard = nil
        let id = UUID()
        listenID = id
        listenTask = Task {
            defer { if listenID == id { listenTask = nil } }
            do {
                let result = try await VoiceRequest().listen(for: map)
                guard listenID == id, !Task.isCancelled else { return }
                guard !result.text.isEmpty else {
                    heard = "Didn't hear anything."
                    return
                }
                heard = "Heard \u{201C}\(result.text)\u{201D}"
                // The diagnostics screen can replace the panel while this listens.
                guard pipeline.canGuide, let button = result.button,
                      self.map?.buttons.contains(where: { $0.id == button.id }) == true else {
                    lastError = "No button matching \u{201C}\(result.text)\u{201D} on this panel."
                    return
                }
                heard = "Heard \u{201C}\(result.text)\u{201D}: guiding to \(button.label ?? "it")"
                startGuidance(to: button)
            } catch is CancellationError {
                // Scanning again or leaving the screen ended the request.
            } catch {
                if listenID == id { lastError = error.localizedDescription }
            }
        }
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
