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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                #if DEBUG
                Section("Developer tools") {
                    NavigationLink("Tracking Diagnostics") {
                        TrackingDebugView(camera: camera)
                    }
                    NavigationLink("Model image spike (Surface)") {
                        ModelImageSpikeView()
                    }
                    NavigationLink("Haptics") {
                        HapticsDebugView()
                    }
                }
                #endif

                
                Section("Developing LiveCameraView") {
                    NavigationLink("Enter LiveCameraView") {
                        LiveCameraView()
                    }
                }
                
                
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

                Section("Run the pipeline") {
                    if surfaceIsLive {
                        // What the scan will capture, so you can aim at the panel.
                        CameraPreview(session: camera.session)
                            .frame(height: 260)
                            .task { try? await camera.start() }
                    }
                    Button("Scan panel") { scan() }
                    Button(guidanceTask == nil ? "Guide to Start" : "Stop") { toggleGuidance() }
                        .disabled(map == nil || !pipeline.canGuide || scanTask != nil)
                    Text(pipeline.liveComponents.contains(.tracking)
                         ? "Keep the panel in view and move your finger toward Start. "
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
        .onChange(of: pipeline.panelReference?.photo.id) { _, _ in
            map = pipeline.panelReference?.detection.map
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
        scanTask?.cancel()
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
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
                    lastError = "Found the buttons but not the edges of the panel. Step back so the whole panel is in view, then scan again."
                }
            } catch is CancellationError {
                // A replacement scan or navigation ended this request.
            } catch {
                if scanID == id { lastError = String(describing: error) }
            }
        }
    }

    private func stopWork() {
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
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

    /// The Start button. A label that is "Start", or has it as one part of
    /// "Start/Pause", wins. Otherwise the shortest label with "Start" as a word,
    /// like "Start Pause" read off a key printed on two lines.
    /// TODO: use TargetMatcher once #30 lands.
    private func startButton(in map: SurfaceMap) -> SurfaceMap.Button? {
        let labelled = map.buttons.compactMap { button in button.label.map { (button, $0) } }
        func words(_ label: String) -> [Substring] {
            label.lowercased().split { !$0.isLetter && !$0.isNumber }
        }

        let exact = labelled.first { _, label in
            label.split(separator: "/").contains {
                $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Start") == .orderedSame
            }
        }
        if let exact { return exact.0 }

        return labelled
            .filter { words($0.1).contains("start") }
            .min { words($0.1).count < words($1.1).count }?.0
    }

    private func toggleGuidance() {
        if let guidanceTask {
            guidanceTask.cancel()
            self.guidanceTask = nil
            guidanceID = nil
            return
        }
        guard pipeline.canGuide, let map, let target = startButton(in: map) else {
            lastError = "No Start button found on the panel."
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
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
