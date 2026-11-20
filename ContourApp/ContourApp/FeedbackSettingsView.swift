import SwiftUI

enum FeedbackPreferenceKeys {
    static let audio = "feedback.audioEnabled"
    static let voice = "feedback.voiceEnabled"
    static let haptics = "feedback.hapticsEnabled"
    static let intensity = "feedback.hapticIntensity"
}

struct FeedbackSettingsView: View {
    @AppStorage(FeedbackPreferenceKeys.audio) private var audio = true
    @AppStorage(FeedbackPreferenceKeys.voice) private var voice = true
    @AppStorage(FeedbackPreferenceKeys.haptics) private var haptics = true
    @AppStorage(FeedbackPreferenceKeys.intensity) private var intensity = 0.85
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Guidance feedback") {
                    Toggle("Sounds", isOn: $audio)
                    Toggle("Voice instructions", isOn: $voice)
                    Toggle("Haptics", isOn: $haptics)
                }
                Section {
                    Slider(value: $intensity, in: 0...1) { Text("Vibration strength") }
                    LabeledContent("Vibration strength", value: intensity.formatted(.percent.precision(.fractionLength(0))))
                } header: {
                    Text("Sustained vibration")
                } footer: {
                    Text("The contact pulse uses full strength. This setting adjusts the sustained vibration; zero silences haptics.")
                }
            }
            .navigationTitle("Feedback")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
