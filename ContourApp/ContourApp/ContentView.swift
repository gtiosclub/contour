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
    @State private var camera = CameraService()

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

                Section("Run the mock pipeline") {
                    Button("Scan panel") { scan() }
                    Button(guidanceTask == nil ? "Guide to Start" : "Stop") { toggleGuidance() }
                        .disabled(map == nil)
                    Text("Guidance output goes to the console. Experience's rig "
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
                // A zero-byte photo: MockSurfaceUnderstanding ignores it entirely.
                // Experience replaces this with a real capture from CaptureFlow.
                map = try await pipeline.detectPanel(
                    in: PanelPhoto(
                        data: Data(),
                        pixelSize: PixelSize(width: 4032, height: 3024),
                        timestamp: Date()
                    )
                )
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    private func toggleGuidance() {
        if let guidanceTask {
            guidanceTask.cancel()
            self.guidanceTask = nil
            return
        }
        guard let target = map?.button(labelled: "Start") else { return }
        guidanceTask = Task {
            await pipeline.guide(to: target)
            guidanceTask = nil
        }
    }
}

#Preview {
    ContentView(pipeline: .mock())
}
