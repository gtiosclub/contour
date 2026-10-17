import ContourCore
import SwiftUI
import UIKit

struct LiveCameraView: View {
    let camera: CameraService
    let pipeline: ContourPipeline
    let experience: CameraLaunchModel
    @AccessibilityFocusState private var statusFocused: Bool

    private var primaryTitle: String {
        if experience.busy { return "Stop" }
        if !experience.ready { return "Retry camera" }
        return experience.map == nil || !pipeline.canGuide || experience.map?.buttons.isEmpty == true
            ? "Scan panel" : "Say a button"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if experience.usesCamera {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea().accessibilityHidden(true)
            }
            ScrollView {
                VStack(spacing: 24) {
                    Text(experience.status)
                        .font(.title2.bold())
                        .accessibilityFocused($statusFocused)
                        .accessibilitySortPriority(3)
                    if !experience.usesCamera {
                        Text("Simulator demo: panel detection and finger movement are simulated.")
                            .font(.callout)
                    }
                    if let error = experience.error { Text(error).foregroundStyle(.yellow) }
                    Button {
                        if experience.busy { experience.stop() }
                        else if !experience.ready { experience.setActive(true) }
                        else if primaryTitle == "Scan panel" { experience.scan() }
                        else { experience.sayAButton() }
                    } label: {
                        Text(primaryTitle)
                            .font(.title.bold()).multilineTextAlignment(.center)
                            .padding(24)
                            .frame(width: 210, height: 210)
                            .background(.ultraThickMaterial, in: Circle())
                    }
                    .accessibilityLabel(primaryTitle)
                    .accessibilityHint(experience.busy ? "Cancels the current scan, microphone, or guidance."
                        : !experience.ready ? "Tries to start the camera again."
                        : primaryTitle == "Scan panel" ? "Photographs and identifies the panel's buttons."
                        : "Listens for a button name for up to eight seconds.")
                    .accessibilitySortPriority(2)
                    if let map = experience.map, pipeline.canGuide, !map.buttons.isEmpty {
                        Text("Choose a button").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(Array(map.buttons.enumerated()), id: \.element.id) { index, button in
                            Button(button.label ?? "Unlabelled button \(index + 1)") { experience.choose(button) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityHint("Starts finger guidance to this button.")
                                .disabled(experience.busy || !experience.ready)
                        }
                    }
                    if experience.map != nil {
                        Button("Scan again") { experience.scan() }
                            .buttonStyle(.bordered)
                            .disabled(!experience.ready)
                            .accessibilityHint("Cancels current work and scans a new panel.")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 24))
                .padding()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { statusFocused = true }
        .onChange(of: experience.status) { _, message in
            // State transitions only; tracking's per-frame output stays in the feedback engine.
            // VoiceRequest announces listening before it opens the microphone.
            if !experience.listening {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        .onChange(of: experience.error) { _, error in
            if let error { UIAccessibility.post(notification: .announcement, argument: error) }
        }
        .onChange(of: pipeline.panelReference?.photo.id) { old, new in
            if old != new { experience.referenceChanged() }
        }
    }
}

#Preview {
    let camera = CameraService()
    let pipeline = ContourPipeline.mock()
    LiveCameraView(camera: camera, pipeline: pipeline,
                   experience: CameraLaunchModel(camera: camera, pipeline: pipeline))
}
