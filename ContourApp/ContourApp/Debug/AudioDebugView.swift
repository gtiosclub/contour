#if DEBUG
import AVFoundation
import Combine
import ContourFeedback
import SwiftUI

/// One button runs an eight-second left/right and low/high tone test.
@MainActor
struct AudioDebugView: View {
    @StateObject private var test = AudioButtonTest()

    var body: some View {
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
        }
        .padding()
        .navigationTitle("Directional Audio")
        .onDisappear { test.stop() }
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
                #if os(iOS)
                // Temporary DEBUG-screen setup until Nancy's session config lands.
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                #endif

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
#endif


#Preview {
    AudioDebugView()
}
