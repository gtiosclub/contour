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

#if DEBUG
import ContourFeedback
import SwiftUI

struct HapticsDebugView: View {

    @State private var haptics = HapticEngineManager()
    @State private var intensity: Float = 0.5
    @State private var sharpness: Float = 0.5
    @State private var continuousOn = false
    @State private var startError: String?

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
        }
        .navigationTitle("Haptics")
        .onChange(of: intensity) { _, _ in push() }
        .onChange(of: sharpness) { _, _ in push() }
        .onAppear { push() }
        .onDisappear { haptics.stop() }
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
