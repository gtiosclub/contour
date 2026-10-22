#if DEBUG
import SwiftUI
import Tracking

/// Supplied evidence only: this screen does not run a camera or a tracker.
struct GuidanceStatusScenariosView: View {
    @State private var index = 0
    @State private var largeText = false
    private let scenarios: [HybridTrackingDiagnostics] = [
        .init(mode: .visual, message: "Panel visible. Building calibration from accepted views.",
              calibrationFrames: 3, source: .visual),
        .init(mode: .corrected, message: "Visual features are correcting the world estimate.",
              calibrationFrames: 12, source: .fused, calibrationReady: true, visualVerificationAge: 0.1),
        .init(mode: .predicted, message: "Using a recent world estimate while visual features are covered.",
              calibrationFrames: 12, source: .world, calibrationReady: true, visualVerificationAge: 1.5),
        .init(mode: .reacquiring,
              message: "Calibration is retained, but prediction is paused. Show the panel again so its alignment can be checked. Reflections or a covered panel can prevent a reliable visual check; no usable alignment is currently supplying guidance.",
              calibrationFrames: 12, repositionReason: .suspectedGlare,
              source: .unavailable, calibrationReady: true)
    ]

    var body: some View {
        List {
            Section("Scripted evidence — no live tracking") {
                Toggle("Accessibility text size", isOn: $largeText)
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.15))
                    .frame(height: 100)
                    .overlay(Text("Preview placeholder"))
                GuidanceStatusRow(snapshot: GuidanceStatusSnapshot(diagnostics: scenarios[index]))
                    .dynamicTypeSize(largeText ? .accessibility3 : .large)
                Button("Next status") { index = (index + 1) % scenarios.count }
                Button("Restart sequence") { index = 0 }
            }
            Section {
                Text("Cycle visual, corrected AR, prediction, and loss. Preview and buttons should stay in place within each text size. Scroll the status area to read long messages.")
            }
        }
        .navigationTitle("Status scenarios")
    }
}
#endif
