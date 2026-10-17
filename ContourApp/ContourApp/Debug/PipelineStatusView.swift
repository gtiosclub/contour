//
//  PipelineStatusView.swift
//  ContourApp — Debug
//
//  What the scaffold's home screen used to show: which components are live
//  and which are mocked, the panel the last scan returned, any tracking
//  error, and the latest guidance. Read-only — the main flow does the work.
//

#if DEBUG
import ContourCore
import SwiftUI
import Tracking

struct PipelineStatusView: View {
    let pipeline: ContourPipeline

    var body: some View {
        List {
            Section("Components") {
                ForEach(ContourPipeline.Component.allCases, id: \.self) { component in
                    let live = pipeline.liveComponents.contains(component)
                    LabeledContent(component.rawValue) {
                        Text(live ? "live" : "mocked")
                            .foregroundStyle(live ? .green : .secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(component.rawValue), owned by \(component.team), \(live ? "live" : "mocked")")
                }
            }

            Section("Detected panel") {
                if let reference = pipeline.panelReference {
                    let map = reference.detection.map
                    LabeledContent("Panel confidence",
                                   value: map.confidence.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Trackable outline", value: reference.detection.quad == .fullFrame ? "no (full frame)" : "yes")
                    LabeledContent("Can guide", value: pipeline.canGuide ? "yes" : "no")
                    ForEach(map.buttons) { button in
                        LabeledContent(button.label ?? "Unlabelled") {
                            Text(button.confidence.formatted(.number.precision(.fractionLength(2))))
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text("Not scanned yet.").foregroundStyle(.secondary)
                }
                if let trackingError = pipeline.trackingError {
                    Text(trackingError).foregroundStyle(.red)
                }
            }

            Section("Guidance") {
                LabeledContent("Tracking method", value: pipeline.trackingMethod.rawValue)
                if let state = pipeline.latestGuidance {
                    if let vector = state.vector {
                        LabeledContent("Distance", value: vector.normalizedDistance.formatted(.number.precision(.fractionLength(3))))
                        LabeledContent("Direction", value: "dx \(vector.direction.dx.formatted(.number.precision(.fractionLength(2)))), dy \(vector.direction.dy.formatted(.number.precision(.fractionLength(2))))")
                    }
                    LabeledContent("Outcome", value: state.outcome?.rawValue ?? "none")
                } else {
                    Text("No guidance yet.").foregroundStyle(.secondary)
                }
                LabeledContent("Last outcome", value: pipeline.lastOutcome?.rawValue ?? "none")
                Text(guidanceExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Pipeline Status")
    }

    private var guidanceExplanation: String {
        if pipeline.liveComponents.contains(.tracking) {
            return "Keep the panel in view and move your finger toward the selected target. It vibrates faster as you get closer."
        }
        if pipeline.liveComponents.contains(.feedback) {
            return "Guidance vibrates. Tracking is still simulated, so the phone acts out a finger moving to the chosen target."
        }
        return "Guidance output goes to the console. Experience's rig is the Harness scheme on macOS."
    }
}

/// The exact photo the last scan sent to Surface, with what came back.
struct CapturedPanelReviewScreen: View {
    let pipeline: ContourPipeline

    var body: some View {
        ScrollView {
            if let reference = pipeline.panelReference, !reference.photo.data.isEmpty {
                CapturedPanelReviewView(reference: reference)
                    .padding()
            } else {
                Text("No captured photo yet. Scan a panel with Surface Understanding live; the mock pipeline sends an empty photo.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle("Captured Panel Review")
    }
}
#endif
