//
//  MockRunDebugView.swift
//  ContourApp/Debug — Experience / Mocks & Integration
//
//  Plays the ContourMocks `MockRun` presets over the issue #12 keypad: the
//  panel's buttons, a fingertip dot moving at 30 Hz, and the GuidanceState
//  GuidanceMath computes for each frame. No camera, no tracker.
//
//  Not linked from DebugMenu yet; add
//      NavigationLink("Mock Runs") { MockRunDebugView() }
//  there to reach it.
//
//  COORDINATES: panel space, (0,0) top-left, y DOWN — the same as SwiftUI's,
//  so a panel point maps to the view by scaling, with no flip.
//

#if DEBUG
import ContourCore
import ContourMocks
import SwiftUI

struct MockRunDebugView: View {

    @State private var preset: MockRun.Preset = .straight
    @State private var frame: TrackingFrame?
    @State private var guidance: GuidanceState?
    @State private var playback: Task<Void, Never>?

    private let map = MockSurfaceMaps.microwaveKeypad

    init() {}

    var body: some View {
        VStack(spacing: 16) {
            Picker("Run", selection: $preset) {
                ForEach(MockRun.Preset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: preset) { stop(); reset() }

            MockPanelDiagram(
                map: map,
                target: preset.run.targetButtonID,
                fingertip: frame?.fingertip
            )
            .aspectRatio(1.6, contentMode: .fit)

            Text(status)
                .font(.callout.monospacedDigit())
                .foregroundStyle(frame?.trackingQuality == .lost ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Status: \(status)")

            Button(playback == nil ? "Play" : "Stop") {
                playback == nil ? play() : stop()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(playback == nil
                ? "Plays the \(preset.title) mock run at 30 frames per second"
                : "Stops the mock run")

            Spacer()
        }
        .padding()
        .navigationTitle("Mock Runs")
        .onDisappear { stop() }
    }

    private var status: String {
        guard let frame else { return "Not playing. Choose a run and press Play." }
        let seconds = frame.timestamp.timeIntervalSince(MockTrackingSource.fixedEpoch)
        let time = String(format: "t = %.2f s", seconds)
        if let guidance {
            return "\(time) · \(PrintingFeedbackEngine.describe(guidance))"
        }
        return time
    }

    private func play() {
        reset()
        let source = MockGuidanceSource(run: preset.run, map: map)
        let tracking = source.tracking.frames()
        playback = Task {
            for await next in tracking {
                if Task.isCancelled { break }
                frame = next
                guidance = GuidanceMath.compute(frame: next, target: source.target)
            }
            // A cancelled run must not clear the handle of the run that replaced it.
            if !Task.isCancelled { playback = nil }
        }
    }

    private func stop() {
        playback?.cancel()
        playback = nil
    }

    private func reset() {
        frame = nil
        guidance = nil
    }
}

/// The keypad drawn in panel space, with the fingertip on top.
private struct MockPanelDiagram: View {
    let map: SurfaceMap
    let target: UUID
    let fingertip: PanelPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.gray.opacity(0.15))
                    .accessibilityHidden(true)

                ForEach(map.buttons) { button in
                    let isTarget = button.id == target
                    let name = button.label ?? "Cancel, icon only"
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isTarget ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.25))
                        .overlay {
                            Text(button.label ?? "✕")
                                .font(.caption.weight(.semibold))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isTarget ? Color.accentColor : .clear, lineWidth: 2)
                        }
                        .frame(width: size.width * button.bounds.width,
                               height: size.height * button.bounds.height)
                        .position(x: size.width * button.bounds.center.x,
                                  y: size.height * button.bounds.center.y)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(isTarget ? "\(name), target" : name)
                        .accessibilityValue("Confidence \(Int((button.confidence * 100).rounded())) percent")
                }

                if let fingertip {
                    Circle()
                        .fill(.red)
                        .frame(width: 18, height: 18)
                        .position(x: size.width * fingertip.x, y: size.height * fingertip.y)
                        .accessibilityLabel("Mock fingertip")
                        .accessibilityValue(String(format: "x %.2f, y %.2f", fingertip.x, fingertip.y))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mock microwave keypad")
    }
}
#endif
