//  TestExperienceView.swift
//  ContourApp — Experience prototype
//  Experience Subteam - Evan

#if DEBUG
import AVFoundation
import ContourCore
import ContourFeedback
import CoreHaptics
import SwiftUI

/// Tests the independent experience engines with a placeholder guidance vector.
@MainActor
struct TestExperienceView: View {
    @State private var haptics = HapticsExperienceEngine()
    @State private var audio = AudioExperienceEngine()
    @State private var voice = VoiceExperienceEngine()
    @State private var position = ExperiencePadPosition(x: -1, y: -1)
    @State private var didReachTarget = false
    @State private var isTesting = false
    @State private var directionInstruction = ExperienceDirectionInstruction()
    @AppStorage("experienceTest.hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("experienceTest.audioEnabled") private var audioEnabled = true
    @AppStorage("experienceTest.voiceEnabled") private var voiceEnabled = true
    @AppStorage("experienceTest.hapticIntensity") private var hapticIntensity = 0.85
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
                if isTesting && didReachTarget {
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
                Text(directionInstruction.text)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                Button(isTesting ? "Stop test" : "Start test") {
                    if isTesting {
                        stop()
                    } else {
                        guard canStart, scenePhase == .active else { return }
                        didReachTarget = false
                        directionInstruction = ExperienceDirectionInstruction()
                        directionInstruction.update(stubGuidance, at: ProcessInfo.processInfo.systemUptime)
                        isTesting = true
                        syncChannels()
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
                Text("0 is on target; 1 is far away. Far haptic pulses share the audio beat. At distance ≤ 0.25, haptics become continuous and grow stronger and crisper nearby, up to your selected intensity. Move back to ≥ 0.30 to return to pulses. The center snaps to distance 0 and plays success once. Drag away to resume. Direction controls voice guidance only.")
                Text("Audio uses a soft synthesized pluck, 1–6 notes per second, at the same volume during speech. Start with a comfortable device volume. Sound plays even in Silent Mode. Leaving this page or the app stops all channels; press Start to resume.")
            }
        }
        .navigationTitle("Test Experience")
        .task(id: isTesting) {
            guard isTesting else { return }
            var lastBeat: ContinuousClock.Instant?
            while !Task.isCancelled && isTesting {
                updateInstruction()
                if distance == 0 {
                    // Proximity is paused while the one-shot success completes.
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    continue
                }
                if !audio.isRunning && !haptics.isRunning && !voice.isRunning {
                    stop()
                    return
                }
                let now = ContinuousClock.now
                if lastBeat == nil || now >= lastBeat!.advanced(by: .seconds(1 / audioFrequency)) {
                    lastBeat = now
                    // Both channels receive the same future deadline, avoiding
                    // independent timer drift. Hardware latency is best-effort.
                    let deadline = ProcessInfo.processInfo.systemUptime + 0.04
                    if audioEnabled { audio.playPulse(at: deadline) }
                    if hapticsEnabled { haptics.pulse(at: deadline) }
                }
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
            }
        }
        .onChange(of: distance) { _, value in
            guard isTesting else { return }
            if value == 0 {
                announceArrival()
                return
            }
            if didReachTarget {
                didReachTarget = false
                syncChannels()
                return
            }
            if hapticsEnabled && supportsHaptics { haptics.update(distance: value) }
            if audio.isRunning { audio.update(distance: value) }
        }
        .onChange(of: hapticIntensity) { _, value in
            haptics.setIntensity(value)
        }
        .onChange(of: hapticsEnabled) { _, _ in syncChannels() }
        .onChange(of: audioEnabled) { _, _ in syncChannels() }
        .onChange(of: voiceEnabled) { _, _ in syncChannels() }
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

    private func syncChannels() {
        guard isTesting, scenePhase == .active, canStart else {
            stop()
            return
        }
        if voiceEnabled {
            do { try voice.start() } catch { /* Exposed through voice.lastError. */ }
        } else {
            voice.stop()
        }
        updateInstruction()
        if distance == 0 {
            if !audioEnabled { audio.stop() }
            if !hapticsEnabled { haptics.stop() }
            announceArrival()
            return
        }
        if audioEnabled {
            do {
                try audio.start(distance: distance, externallyClocked: true)
            } catch {
                // The observable engine exposes the error without disabling
                // the haptic channel, which can continue independently.
            }
        } else {
            audio.stop()
        }
        if hapticsEnabled && supportsHaptics {
            haptics.setIntensity(hapticIntensity)
            haptics.start(distance: distance, externallyClocked: true)
        } else {
            haptics.stop()
        }
        if !audio.isRunning && !haptics.isRunning && !voice.isRunning {
            stop()
        }
    }

    private func announceArrival() {
        guard isTesting, !didReachTarget else { return }
        didReachTarget = true
        updateInstruction()
        // Flush ongoing/queued proximity feedback before confirmation.
        haptics.setIntensity(hapticIntensity)
        if hapticsEnabled && supportsHaptics {
            haptics.playSuccess()
        } else {
            haptics.stop()
        }
        if audioEnabled {
            do { try audio.playSuccess() } catch { /* Exposed through audio.lastError. */ }
        } else {
            audio.stop()
        }
    }

    private func stop() {
        voice.stop()
        audio.stop()
        haptics.stop()
        isTesting = false
        didReachTarget = false
        directionInstruction = ExperienceDirectionInstruction()
    }

    private func updateInstruction() {
        let now = ProcessInfo.processInfo.systemUptime
        directionInstruction.update(stubGuidance, at: now)
        if voiceEnabled {
            voice.update(directionInstruction.voiceGuidance, distance: distance, at: now)
        }
    }
}

/// Completes one axis before switching. Text and speech consume the same decision.
private struct ExperienceDirectionInstruction {
    private(set) var text = "Press Start to begin."
    private(set) var voiceGuidance: ExperienceVoiceGuidance = .paused

    private enum Direction: String, Equatable {
        case left, right, up, down

        var isHorizontal: Bool { self == .left || self == .right }

        func phrase(near: Bool) -> String {
            switch self {
            case .left: return near ? "A little to the left." : "Move left."
            case .right: return near ? "A little to the right." : "Move right."
            case .up: return near ? "A little upward." : "Move up."
            case .down: return near ? "A little downward." : "Move down."
            }
        }
    }

    private var direction: Direction?
    private var candidate: Direction?
    private var candidateSince = 0.0
    private var previousTime: Double?
    private var near = false

    mutating func update(_ vector: GuidanceVector, at time: Double) {
        guard time.isFinite, vector.normalizedDistance.isFinite,
              vector.normalizedDistance >= 0,
              vector.direction.dx.isFinite, vector.direction.dy.isFinite else {
            self = Self()
            text = "Guidance paused."
            return
        }
        guard previousTime.map({ time > $0 }) ?? true else { return }
        // Arrival is always based on the actual position, never prediction.
        if vector.normalizedDistance == 0 {
            self = Self()
            text = "Target reached."
            voiceGuidance = .arrived
            return
        }
        let remaining = SIMD2(vector.direction.dx, vector.direction.dy) * vector.normalizedDistance
        previousTime = time
        if vector.normalizedDistance <= 0.25 { near = true }
        if vector.normalizedDistance >= 0.30 { near = false }

        // Lock the selected axis until its actual remaining offset is almost
        // zero. Never switch merely because the other axis becomes larger.
        // This tolerance uses distance-scaled offsets, not unit-vector components.
        let deadZone = 0.02
        let horizontal: Direction = remaining.x >= 0 ? .right : .left
        let vertical: Direction = remaining.y >= 0 ? .down : .up
        if abs(remaining.x) <= deadZone && abs(remaining.y) <= deadZone {
            direction = nil
            candidate = nil
            text = "Move slowly."
            voiceGuidance = .slowly
            return
        }
        guard let current = direction else {
            let initial = abs(remaining.x) >= abs(remaining.y) ? horizontal : vertical
            direction = initial
            text = initial.phrase(near: near)
            voiceGuidance = .direction(.init(rawValue: initial.rawValue)!, near: near)
            return
        }
        let currentRemaining = current.isHorizontal ? remaining.x : remaining.y
        let otherRemaining = current.isHorizontal ? remaining.y : remaining.x
        let actualSameAxis = current.isHorizontal ? horizontal : vertical
        let otherDirection = current.isHorizontal ? vertical : horizontal
        let reversed = abs(currentRemaining) > deadZone && actualSameAxis != current
        let desired: Direction
        if reversed {
            // Correct an observed overshoot; never anticipate a reversal.
            desired = actualSameAxis
        } else if abs(currentRemaining) <= deadZone && abs(otherRemaining) > deadZone {
            desired = otherDirection
        } else {
            desired = current
        }
        if desired == current {
            candidate = nil
        } else if candidate != desired {
            candidate = desired
            candidateSince = time
        } else if time - candidateSince >= 0.12 {
            // Confirm alignment or a real overshoot briefly to reject jitter.
            direction = desired
            candidate = nil
        }
        text = (direction ?? current).phrase(near: near)
        voiceGuidance = .direction(.init(rawValue: (direction ?? current).rawValue)!, near: near)
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
