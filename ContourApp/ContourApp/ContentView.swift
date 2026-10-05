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
            return
        }
        guard let map, let target = startButton(in: map) else {
            lastError = "No Start button found on the panel."
            return
        }
        guidanceTask = Task {
            await pipeline.guide(to: target)
            guidanceTask = nil
        }
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
