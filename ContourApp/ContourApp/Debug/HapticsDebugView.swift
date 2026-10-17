//
//  HapticsDebugView.swift
//  ContourApp — Debug
//
//  The rig for Karan's HapticEngineManager. Two sliders, a start/stop toggle, a
//  tap button, and the engine's state. Run it on a real iPhone: the Simulator
//  has no Taptic Engine and will report "unsupported".
//
//  Things to try before calling the engine done:
//    - Drag either slider fast. The vibration should follow with no stutter.
//    - Tap while the continuous vibration is running.
//    - Background the app for ten seconds and come back. It should resume.
//    - Lock and unlock the phone. Same.
//  The reset count should stay at zero through all of that.
//
//  The "Guidance models" section feels the two bake-off models (#17, #54)
//  through the real LiveFeedbackEngine, haptics only: pick a model, switch
//  Guide on, and drag the distance. Switching models stops the old one first.
//

#if DEBUG
import ContourCore
import ContourFeedback
import SwiftUI

struct HapticsDebugView: View {

    @State private var haptics = HapticEngineManager()
    @State private var intensity: Float = 0.5
    @State private var sharpness: Float = 0.5
    @State private var continuousOn = false
    @State private var startError: String?

    @State private var guideModel = ChosenGuidanceModel.current
    @State private var guideEngine = LiveFeedbackEngine(model: ChosenGuidanceModel.current, audio: false, speech: false)
    @State private var guiding = false
    @State private var guideDistance = 0.5

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("State", value: haptics.state.rawValue)
                LabeledContent("Reset count", value: "\(haptics.resetCount)")
                if !haptics.isSupported {
                    Text("This device has no haptics. Run on a real iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let startError {
                    Text(startError).foregroundStyle(.red)
                }
            }

            Section("Continuous") {
                Toggle("Vibrate", isOn: $continuousOn)
                    .onChange(of: continuousOn) { _, on in
                        if on {
                            startError = nil
                            do {
                                try haptics.start()
                            } catch {
                                startError = error.localizedDescription
                                continuousOn = false
                            }
                        } else {
                            haptics.stop()
                        }
                    }

                slider("Intensity", value: $intensity)
                slider("Sharpness", value: $sharpness)
            }

            Section("Transient") {
                Button("Tap") {
                    haptics.tap(intensity: intensity, sharpness: sharpness)
                }
                Text("Uses the slider values. Should work while the continuous vibration is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            guidanceSection
        }
        .navigationTitle("Haptics")
        .onChange(of: intensity) { _, _ in push() }
        .onChange(of: sharpness) { _, _ in push() }
        .onAppear { push() }
        .onDisappear {
            haptics.stop()
            guiding = false
            let engine = guideEngine
            Task { await engine.stop() }
        }
    }

    private var guidanceSection: some View {
        Section("Guidance models") {
            Picker("Model", selection: $guideModel) {
                ForEach(GuidanceModelKind.allCases, id: \.self) { kind in
                    Text(kind == ChosenGuidanceModel.kind ? "\(kind.displayName) (chosen)" : kind.displayName)
                        .tag(kind)
                }
            }
            Toggle("Guide", isOn: $guiding)
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Distance") {
                    Text(guideDistance.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                }
                Slider(value: $guideDistance, in: 0...1)
                    .accessibilityLabel("Distance to the target, zero is on it")
            }
            HStack {
                ForEach(OutcomeSignal.allCases, id: \.self) { outcome in
                    Button(outcome.rawValue) { present(.outcome(outcome, at: .now)) }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }
        }
        .onChange(of: guideModel) { _, kind in
            let old = guideEngine
            let new = LiveFeedbackEngine(model: kind, audio: false, speech: false)
            guideEngine = new
            let state = guidingState()
            let resume = guiding
            Task {
                await old.stop()
                if resume { await new.present(state) }
            }
        }
        .onChange(of: guiding) { _, on in
            if on {
                present(guidingState())
            } else {
                let engine = guideEngine
                Task { await engine.stop() }
            }
        }
        .onChange(of: guideDistance) { _, _ in
            if guiding { present(guidingState()) }
        }
    }

    /// The target straight above the finger, `guideDistance` away.
    private func guidingState() -> GuidanceState {
        GuidanceState(
            timestamp: .now,
            vector: GuidanceVector(direction: PanelVector(dx: 0, dy: -1), normalizedDistance: guideDistance)
        )
    }

    private func present(_ state: GuidanceState) {
        let engine = guideEngine
        Task { await engine.present(state) }
    }

    private func push() {
        haptics.update(intensity: intensity, sharpness: sharpness)
    }

    private func slider(_ title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...1)
                .accessibilityLabel(title)
        }
    }
}

#Preview {
    NavigationStack { HapticsDebugView() }
}
#endif
