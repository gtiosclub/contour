//
//  SpeechDebugView.swift
//  ContourApp
//
//  Created by Rishika Vunnama on 10/15/26.
//
//  The rig for SpeechQueue. Queue lines at each priority, watch what the
//  channel reports, and turn on the directional tone underneath to hear it duck
//  while a line is said (#114). Every word should be understandable with
//  headphones and on the speaker.
//

#if DEBUG
import ContourCore
import ContourFeedback
import SwiftUI

struct SpeechDebugView: View {

    @State private var queue: SpeechQueue
    @State private var activity: SpeechActivity = .silent
    @State private var toneOn = false
    private let audio = DirectionalAudio()

    /// Owns a queue unless you hand it one.
    init(queue: SpeechQueue = SpeechQueue()) {
        _queue = State(initialValue: queue)
    }

    var body: some View {
        Form {
            Section("Queue") {
                LabeledContent("Now", value: describe(activity))
                Button("Guidance (low, expires 2s)") {
                    enqueue(Utterance(text: "Left a bit, down a bit", priority: .low, expiresAfter: .seconds(2)))
                }
                Button("Stage change (normal)") {
                    enqueue(Utterance(text: "Target found. Hold steady.", priority: .normal, expiresAfter: .seconds(6)))
                }
                Button("Arrival (interrupting)") {
                    enqueue(Utterance(text: "You have arrived.", priority: .interrupting))
                }
                Button("Stop", role: .destructive) {
                    Task { await queue.stop() }
                }
            }

            Section("Ducking") {
                Toggle("Directional tone underneath", isOn: $toneOn)
                Text("The tone drops to a quarter under a normal or low line and goes silent under an interrupting one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Speech")
        .task {
            for await now in queue.activityUpdates() {
                activity = now
                await audio.duck(for: now)
            }
        }
        .onChange(of: toneOn) { _, on in
            Task {
                if on {
                    // Target up and a little right, mid-panel: a high, slightly right tone.
                    let vector = GuidanceVector(direction: PanelVector(dx: 0.3, dy: -0.95), normalizedDistance: 0.3)
                    await audio.play(for: GuidanceState(timestamp: .now, vector: vector))
                } else {
                    await audio.stop()
                }
            }
        }
        .onDisappear {
            toneOn = false
            Task {
                await queue.stop()
                await audio.stop()
                await audio.duck(for: .silent)
            }
        }
    }

    private func enqueue(_ utterance: Utterance) {
        Task { await queue.enqueue(utterance) }
    }

    private func describe(_ activity: SpeechActivity) -> String {
        switch activity {
        case .silent: "Silent"
        case .speaking(let priority): "Speaking (\(priority))"
        }
    }
}

#Preview {
    NavigationStack { SpeechDebugView() }
}
#endif
