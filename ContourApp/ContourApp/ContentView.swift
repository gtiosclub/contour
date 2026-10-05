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
    @State private var listening = false
    @State private var heard: String?

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
                        .disabled(map == nil)
                    Button(listening ? "Listening…" : "Say a button") { sayAButton() }
                        .disabled(map == nil || listening || guidanceTask != nil)
                    if let heard {
                        Text(heard).foregroundStyle(.secondary)
                    }
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
    }

    private func scan() {
        lastError = nil
        Task {
            do {
                let photo = try await photoToScan()
                map = try await pipeline.detectPanel(in: photo)
                if pipeline.liveComponents.contains(.tracking),
                   pipeline.panelReference?.detection.quad == .fullFrame {
                    lastError = "Found the buttons but not the edges of the panel, so guidance "
                        + "can't follow it. Step back so the whole panel is in view, then scan again."
                }
            } catch {
                lastError = String(describing: error)
            }
        }
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
            self.guidanceTask = nil
            return
        }
        guard let map, let target = ButtonLookup.button(for: "start", in: map) else {
            lastError = "No Start button found on the panel."
            return
        }
        startGuidance(to: target)
    }

    private func startGuidance(to target: SurfaceMap.Button) {
        guidanceTask = Task {
            await pipeline.guide(to: target)
            guidanceTask = nil
        }
    }

    /// Listen for a button's name, then guide to it.
    private func sayAButton() {
        guard let map else { return }
        lastError = nil
        heard = nil
        listening = true
        Task {
            defer { listening = false }
            do {
                let result = try await VoiceRequest().listen(for: map)
                guard !result.text.isEmpty else {
                    heard = "Didn't hear anything."
                    return
                }
                heard = "Heard \u{201C}\(result.text)\u{201D}"
                guard let button = result.button else {
                    lastError = "No button matching \u{201C}\(result.text)\u{201D} on this panel."
                    return
                }
                heard = "Heard \u{201C}\(result.text)\u{201D}: guiding to \(button.label ?? "it")"
                startGuidance(to: button)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
