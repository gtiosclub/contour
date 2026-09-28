#if DEBUG
import ContourCore
import ContourMocks
import SwiftUI

struct MockRunDebugView: View {
    private enum Preset: String, CaseIterable, Identifiable {
        case straight = "Straight"
        case overshoot = "Overshoot"
        case dropout = "With Dropout"

        var id: Self { self }

        var run: MockRun {
            switch self {
            case .straight: .straight
            case .overshoot: .overshoot
            case .dropout: .withDropout
            }
        }
    }

    @State private var preset: Preset = .straight
    @State private var latestFrame: TrackingFrame?
    @State private var playbackTask: Task<Void, Never>?

    private let map = MockSurfaceMap.microwave

    var body: some View {
        VStack(spacing: 20) {
            Picker("Run", selection: $preset) {
                ForEach(Preset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            PanelDiagram(map: map, fingertip: latestFrame?.fingertip)
                .aspectRatio(1, contentMode: .fit)

            if latestFrame?.trackingQuality == .lost {
                Text("Tracking lost")
                    .foregroundStyle(.orange)
            } else {
                Text("Fingertip is moving at 30 Hz")
                    .foregroundStyle(.secondary)
            }

            Button(playbackTask == nil ? "Play Run" : "Stop") {
                togglePlayback()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Mock Runs")
        .onDisappear { stopPlayback() }
    }

    private func togglePlayback() {
        if playbackTask == nil {
            let source = MockTrackingSource(run: preset.run, map: map)
            playbackTask = Task {
                for await frame in source.frames() {
                    if Task.isCancelled { return }
                    latestFrame = frame
                }
                playbackTask = nil
            }
        } else {
            stopPlayback()
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
    }
}

private struct PanelDiagram: View {
    let map: SurfaceMap
    let fingertip: PanelPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.gray.opacity(0.15))

                ForEach(map.buttons) { button in
                    Text(button.label ?? "×")
                        .font(.caption.weight(.semibold))
                        .frame(
                            width: proxy.size.width * button.bounds.width,
                            height: proxy.size.height * button.bounds.height
                        )
                        .background(.blue.opacity(button.confidence))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .position(
                            x: proxy.size.width * button.bounds.center.x,
                            y: proxy.size.height * button.bounds.center.y
                        )
                }

                if let fingertip {
                    Circle()
                        .fill(.red)
                        .frame(width: 18, height: 18)
                        .position(
                            x: proxy.size.width * fingertip.x,
                            y: proxy.size.height * fingertip.y
                        )
                        .accessibilityLabel("Mock fingertip")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mock microwave panel")
    }
}
#endif
