//
//  AudioDebugView.swift
//  ContourApp — Debug
//
//  The rig for the tone. The first button runs the DirectionalAudioEngine
//  left/right and low/high check. Below it: the guidance tone itself
//  (DirectionalAudio) for the axis check — a target ABOVE the finger must sound
//  HIGHER — and the four outcome earcons. No session setup here: ContourApp
//  configures the one shared audio session at launch.
//

#if DEBUG
import Combine
import ContourCore
import ContourFeedback
import SwiftUI

/// One button runs an eight-second left/right and low/high tone test.
@MainActor
struct AudioDebugView: View {
    @StateObject private var test = AudioButtonTest()
    @State private var axisCheck: Task<Void, Never>?
    @State private var axisStatus = "Up, then down"
    private let guidance = DirectionalAudio()
    private let outcomes = OutcomeAnnouncer(audio: nil, speech: nil)

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Use headphones at a low volume.")
                    .foregroundStyle(.secondary)

                Text(test.status)
                    .multilineTextAlignment(.center)

                Button(test.isRunning ? "Stop Test" : "Run Audio Test") {
                    if test.isRunning {
                        test.stop()
                    } else {
                        test.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Divider()

                Text("Guidance tone: \(axisStatus)")
                    .multilineTextAlignment(.center)
                Button(axisCheck == nil ? "Play Axis Check" : "Stop Axis Check") {
                    axisCheck == nil ? startAxisCheck() : stopAxisCheck()
                }
                .buttonStyle(.bordered)

                Divider()

                Text("Outcome earcons")
                    .font(.headline)
                ForEach(OutcomeSignal.allCases, id: \.self) { outcome in
                    Button(outcome.rawValue) {
                        guard let earcon = outcomes.presentation(for: outcome).earcon else { return }
                        Task { await guidance.play(earcon) }
                    }
                    .accessibilityLabel("Play the \(outcome.rawValue) earcon")
                }
            }
            .padding()
        }
        .navigationTitle("Directional Audio")
        .onDisappear {
            test.stop()
            stopAxisCheck()
        }
    }

    /// The real guidance mapping: up (negative dy) high, then down low.
    private func startAxisCheck() {
        let audio = guidance
        axisCheck = Task { @MainActor in
            let steps: [(String, PanelVector)] = [
                ("target ABOVE: should be HIGH", PanelVector(dx: 0, dy: -1)),
                ("target BELOW: should be LOW", PanelVector(dx: 0, dy: 1)),
            ]
            for (label, direction) in steps {
                axisStatus = label
                await audio.play(for: GuidanceState(
                    timestamp: .now,
                    vector: GuidanceVector(direction: direction, normalizedDistance: 0.3)
                ))
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
            }
            await audio.stop()
            if !Task.isCancelled {   // a cancelled run was already cleared by stopAxisCheck()
                axisStatus = "Done. Was up higher than down?"
                axisCheck = nil
            }
        }
    }

    private func stopAxisCheck() {
        axisCheck?.cancel()
        axisCheck = nil
        Task { await guidance.stop() }
    }
}

@MainActor
private final class AudioButtonTest: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Left → right → low pitch → high pitch"

    private let audio = DirectionalAudioEngine()
    private var task: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // No session setup here: ContourApp configures the one shared
                // session at launch (AudioSessionConfig).
                audio.setVolume(0.15)
                audio.setBeacon(pan: -1, proximity: 0.5)
                try audio.start()
                status = "Left ear"
                try await Task.sleep(for: .seconds(2))

                audio.setBeacon(pan: 1, proximity: 0.5)
                status = "Right ear"
                try await Task.sleep(for: .seconds(2))

                audio.setBeacon(pan: 0, proximity: 0)
                status = "Both ears · low pitch (360 Hz)"
                try await Task.sleep(for: .seconds(2))

                audio.setBeacon(pan: 0, proximity: 1)
                status = "Both ears · high pitch (960 Hz)"
                try await Task.sleep(for: .seconds(2))

                audio.stop()
                status = "Test finished. Did left/right and pitch change correctly?"
                isRunning = false
                task = nil
            } catch is CancellationError {
                // stop() already reset the engine and screen.
            } catch {
                audio.stop()
                status = "Audio test failed: \(error.localizedDescription)"
                isRunning = false
                task = nil
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        audio.stop()
        isRunning = false
        status = "Stopped"
    }
}

#Preview {
    AudioDebugView()
}
#endif
