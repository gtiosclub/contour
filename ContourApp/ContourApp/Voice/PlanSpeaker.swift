//
//  PlanSpeaker.swift
//  ContourApp — throwaway multi-step demo, not for merging
//
//  Says which key is next, whether or not VoiceOver is on. `speak` returns only
//  once the sentence is finished, so the microphone never hears it.
//

import AVFoundation

protocol PlanSpeaking: AnyObject {
    func speak(_ text: String) async
    func stop()
}

final class PlanSpeaker: NSObject, PlanSpeaking, AVSpeechSynthesizerDelegate {
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    private var utterance: AVSpeechUtterance?
    private var finished: CheckedContinuation<Void, Never>?
    private var limit: Task<Void, Never>?

    func speak(_ text: String) async {
        stop()
        guard !Task.isCancelled else { return }
        // The default category goes silent with the ringer switch. This is the
        // microphone's setup too, so listening for next after this changes nothing.
        try? AppAudioSession.activate()
        let next = AVSpeechUtterance(string: text)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finished = continuation
                utterance = next
                synthesizer.speak(next)
                // Speech can fail without calling back. Don't leave the plan waiting.
                limit = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    if !Task.isCancelled { self?.stop() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
        // Let the room go quiet before anything opens the microphone.
        try? await Task.sleep(for: .milliseconds(250))
    }

    func stop() {
        limit?.cancel()
        limit = nil
        if utterance != nil { synthesizer.stopSpeaking(at: .immediate) }
        utterance = nil
        finished?.resume()
        finished = nil
    }

    // The sentence itself goes to the main actor, not its address: kept alive
    // until it's compared, a new sentence can't be made at the same address.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor in self.done(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor in self.done(utterance) }
    }

    /// A late callback from a sentence that was cut off must not end the one after it.
    private func done(_ ended: AVSpeechUtterance) {
        guard ended === utterance else { return }
        limit?.cancel()
        limit = nil
        utterance = nil
        finished?.resume()
        finished = nil
    }
}
