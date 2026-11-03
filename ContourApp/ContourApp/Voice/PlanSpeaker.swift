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
    private var utterance: ObjectIdentifier?
    private var finished: CheckedContinuation<Void, Never>?
    private var limit: Task<Void, Never>?

    func speak(_ text: String) async {
        stop()
        guard !Task.isCancelled else { return }
        // The same setup as VoiceExperienceEngine. After the microphone closes the
        // session may be left routed to the earpiece, and the default category
        // goes silent with the ringer switch.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let next = AVSpeechUtterance(string: text)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finished = continuation
                utterance = ObjectIdentifier(next)
                synthesizer.speak(next)
                // Speech can fail without calling back. Don't leave the plan waiting.
                limit = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    /// A late callback from a sentence that was cut off must not end the one after it.
    private func done(_ id: ObjectIdentifier) {
        guard id == utterance else { return }
        limit?.cancel()
        limit = nil
        utterance = nil
        finished?.resume()
        finished = nil
    }
}
