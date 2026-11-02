//  TestExperienceView.swift
//  ContourApp — Experience prototype
//  Experience Subteam - Evan

#if DEBUG
import AVFoundation
import ContourCore
import ContourFeedback
import CoreHaptics
import SwiftUI

/// Feeds simulated guidance into the same feedback engine used by the app.
@MainActor
struct TestExperienceView: View {
    @State private var feedback = LiveFeedbackEngine()
    @State private var position = ExperiencePadPosition(x: -1, y: -1)
    @State private var isTesting = false
    @State private var arrivalHold = GuidanceArrivalHold()
    private var haptics: HapticsExperienceEngine { feedback.haptics }
    private var audio: AudioExperienceEngine { feedback.audio }
    private var voice: VoiceExperienceEngine { feedback.voice }
    @AppStorage(FeedbackPreferenceKeys.haptics) private var hapticsEnabled = true
    @AppStorage(FeedbackPreferenceKeys.audio) private var audioEnabled = true
    @AppStorage(FeedbackPreferenceKeys.voice) private var voiceEnabled = true
    @AppStorage(FeedbackPreferenceKeys.intensity) private var hapticIntensity = 0.85
    @Environment(\.scenePhase) private var scenePhase

    private var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Same parameter type as GuidanceState.vector. Voice uses direction;
    /// proximity audio and haptics continue to use radial distance only.
    private var stubGuidance: GuidanceVector { position.guidanceVector }

    private var distance: Double { stubGuidance.normalizedDistance }

    private var audioFrequency: Double {
        AudioExperienceEngine.frequency(for: distance) ?? 1
    }

    private var canStart: Bool {
        voiceEnabled || audioEnabled || (hapticsEnabled && supportsHaptics)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Audio feedback", isOn: $audioEnabled)
                Toggle("Haptic feedback", isOn: $hapticsEnabled)
                Toggle("Voice guidance", isOn: $voiceEnabled)
                LabeledContent("Voice", value: voice.isSpeaking ? "Speaking" : voice.isRunning ? "Ready" : "Stopped")
                LabeledContent("Audio", value: audio.isPlayingSuccess ? "Success chime" : audio.isRunning ? "Playing" : "Stopped")
                if isTesting && feedback.didReachTarget {
                    Label("Target reached", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                LabeledContent("Haptics", value: haptics.isRunning ? haptics.mode.rawValue : "Stopped")
                if let error = haptics.lastError {
                    Text(error).foregroundStyle(.red)
                }
                if let error = audio.lastError {
                    Text(error).foregroundStyle(.red)
                }
                if let error = voice.lastError {
                    Text(error).foregroundStyle(.red)
                }
                if !supportsHaptics {
                    Text("Haptics require a supported physical iPhone. Audio can also be tested in Simulator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Feedback channels")
            } footer: {
                Text("Audio, haptics, and voice can be enabled independently. Turning a channel off stops it immediately. Turning it on resumes at the current position.")
            }

            Section {
                LabeledContent("Overall intensity", value: hapticIntensity.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                Slider(value: $hapticIntensity, in: 0...1) {
                    Text("Overall haptic intensity")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
                .accessibilityValue(hapticIntensity.formatted(.percent.precision(.fractionLength(0))))
            } header: {
                Text("Haptic strength")
            } footer: {
                Text("Sets tap strength and maximum continuous strength. Nearby, intensity rises from about 70% to 100% of this setting as sharpness increases. At 0%, haptics are silent.")
            }

            Section {
                Text(feedback.instructionText)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                Button(isTesting ? "Stop test" : "Start test") {
                    if isTesting {
                        stop()
                    } else {
                        guard canStart, scenePhase == .active else { return }
                        isTesting = true
                        updateSettings()
                    }
                }
                .disabled(!isTesting && !canStart)
            } header: {
                Text("Direction instruction")
            } footer: {
                Text("Voice follows the same locked axis. Direction changes interrupt old instructions. Reminders occur only when moving farther away, at least two seconds apart.")
            }

            Section {
                LabeledContent("Distance", value: distance.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                ExperienceDistancePad(position: $position)
                LabeledContent("Stub direction dx", value: stubGuidance.direction.dx.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                LabeledContent("Stub direction dy", value: stubGuidance.direction.dy.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                LabeledContent("Audio frequency", value: String(format: "%.1f Hz", audioFrequency))
                    .monospacedDigit()
                if haptics.isRunning && haptics.mode == .continuous {
                    LabeledContent("Continuous player", value: haptics.continuousPlayerActive ? "Started" : "Stopped")
                    LabeledContent("Haptic intensity", value: haptics.intensity.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                    LabeledContent("Haptic sharpness", value: haptics.sharpness.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                } else {
                    LabeledContent("Haptic pulse frequency", value: String(format: "%.1f Hz", audioFrequency))
                        .monospacedDigit()
                }
            } header: {
                Text("Two-dimensional distance")
            } footer: {
                Text("0 is on target; 1 is far away. Far haptic pulses share the audio beat. At distance ≤ 0.25, haptics become continuous and grow stronger and crisper nearby, up to your selected intensity. Move back to ≥ 0.30 to return to pulses. Entering the center gives one tap; hold for 1.25 seconds for success feedback. Drag away to resume. Direction controls voice guidance only.")
                Text("Audio uses a soft synthesized pluck, 1–6 notes per second, at the same volume during speech. Start with a comfortable device volume. Sound plays even in Silent Mode. Leaving this page or the app stops all channels; press Start to resume.")
            }
        }
        .navigationTitle("Test Experience")
        .task(id: isTesting) {
            guard isTesting else { return }
            // Only simulate incoming guidance; playback scheduling lives in the engine.
            while !Task.isCancelled && isTesting {
                let state = arrivalHold.update(GuidanceState(timestamp: Date(), vector: stubGuidance), at: .now)
                await feedback.present(state)
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        .onChange(of: hapticIntensity) { _, _ in updateSettings() }
        .onChange(of: hapticsEnabled) { _, _ in updateSettings() }
        .onChange(of: audioEnabled) { _, _ in updateSettings() }
        .onChange(of: voiceEnabled) { _, _ in updateSettings() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
            // Stop rather than unexpectedly switching from headphones to speaker.
            stop()
        }
        .onDisappear { stop() }
    }

    private func updateSettings() {
        feedback.setChannels(audio: audioEnabled, voice: voiceEnabled,
                             haptics: hapticsEnabled, intensity: hapticIntensity)
    }

    private func stop() {
        feedback.stop()
        arrivalHold.reset()
        isTesting = false
    }
}

/// Normalized control coordinates. Corners are distance 1; the center is 0.
/// The stub keeps that existing test calibration, rather than recomputing the
/// physical panel distance from tracking. Direction follows ContourCore's axes.
private struct ExperiencePadPosition: Equatable {
    var x: Double
    var y: Double

    var distance: Double { min(hypot(x, y) / sqrt(2), 1) }

    /// The thumb is the simulated fingertip and the center is the target.
    /// Unit direction points toward the target: +dx right, +dy down.
    var guidanceVector: GuidanceVector {
        let towardCenter = PanelVector(dx: -x, dy: -y)
        return GuidanceVector(
            direction: towardCenter.normalized ?? .zero,
            normalizedDistance: distance
        )
    }

    static func resolve(location: CGPoint, size: CGSize, wasCentered: Bool) -> Self {
        let halfWidth = max((size.width - 44) / 2, 1)
        let halfHeight = max((size.height - 44) / 2, 1)
        let dx = location.x - size.width / 2
        let dy = location.y - size.height / 2
        // A small target makes exact zero achievable; hysteresis avoids success
        // chattering when a finger rests close to the target boundary.
        if hypot(dx, dy) <= (wasCentered ? 18 : 12) {
            return Self(x: 0, y: 0)
        }
        return Self(x: Double(min(max(dx / halfWidth, -1), 1)),
                    y: Double(min(max(dy / halfHeight, -1), 1)))
    }

    func location(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(x) * max((size.width - 44) / 2, 1),
                y: size.height / 2 + CGFloat(y) * max((size.height - 44) / 2, 1))
    }
}

/// SwiftUI shapes and a direct drag gesture: no extra directional feedback,
/// axis snapping, stepped ticks, or external UI components.
private struct ExperienceDistancePad: View {
    @Binding var position: ExperiencePadPosition

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear
                Rectangle().fill(.secondary.opacity(0.35)).frame(height: 1).padding(.horizontal, 22)
                Rectangle().fill(.secondary.opacity(0.35)).frame(width: 1).padding(.vertical, 22)
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                Circle()
                    .fill(.clear)
                    .frame(width: 44, height: 44)
                    .glassEffect(.clear.interactive(), in: Circle())
                    .opacity(0.35)
                    .overlay {
                        Circle()
                            .strokeBorder(.primary.opacity(0.18), lineWidth: 0.75)
                    }
                    .overlay {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                    }
                    .position(position.location(in: geometry.size))
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        position = .resolve(location: value.location, size: geometry.size,
                                            wasCentered: position.distance == 0)
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityRepresentation {
            Slider(value: Binding(
                get: { position.distance },
                set: { position = ExperiencePadPosition(x: $0, y: $0) }
            ), in: 0...1) {
                Text("Distance to center")
            }
            .accessibilityValue(position.distance.formatted(.number.precision(.fractionLength(2))))
        }
    }
}

#Preview {
    NavigationStack {
        TestExperienceView()
    }
}

#endif
