//
//  SpeechDebugView.swift
//  ContourApp
//
//  Created by Rishika Vunnama on 10/15/26.
//


import SwiftUI
import ContourCore

struct SpeechDebugView: View {
    let queue: SpeechQueue

    var body: some View {
        VStack(spacing: 16) {
            Button("Guidance (low, expires 2s)") {
                Task {
                    await queue.enqueue(Utterance(text: "Left a bit, down a bit",
                                                  priority: .low,
                                                  expiresAfter: .seconds(2)))
                }
            }
            Button("Stage change (normal)") {
                Task {
                    await queue.enqueue(Utterance(text: "Target found. Hold steady.",
                                                  priority: .normal,
                                                  expiresAfter: .seconds(6)))
                }
            }
            Button("Arrival (interrupting)") {
                Task {
                    await queue.enqueue(Utterance(text: "You have arrived.",
                                                  priority: .interrupting))
                }
            }
            Button("Stop", role: .destructive) {
                Task { await queue.stop() }
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }
}
