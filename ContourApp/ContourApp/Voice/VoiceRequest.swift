//
//  VoiceRequest.swift
//  ContourApp — Officers (integration)
//
//  "Say a button": listen on the device to a whole sentence, then return the
//  button it names on the scanned panel. Uses the same on-device speech setup as
//  LiveCameraView.
//

import AVFoundation
import ContourCore
import Foundation
import Speech
import UIKit
import Synchronization

enum VoiceRequestError: LocalizedError {
    case unavailable, noMicrophone, permissionDenied

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available on this device."
        case .noMicrophone: "No microphone is available."
        case .permissionDenied: "Microphone access is unavailable. Enable it in Settings, or choose a button on screen."
        }
    }
}

struct VoiceRequest {

    /// What was heard, and the button it names, if any.
    struct Heard {
        var text: String
        var button: SurfaceMap.Button?
    }

    /// How long the recognizer can stay silent before the sentence counts as said.
    /// It delivers words in bursts about a second apart, even mid-sentence: stopping
    /// at exactly 1 s cut "cook for a minute and a half" down to "cook for a minute".
    static let sentenceQuiet: Duration = .milliseconds(1500)

    /// Listens to one whole request, until the recognizer finishes a sentence, goes
    /// quiet, or `timeout` passes, then looks up the button it names. Waiting for
    /// the whole sentence keeps "cook for a minute and a half" from stopping at "cook".
    func listen(for map: SurfaceMap, timeout: Duration = .seconds(8)) async throws -> Heard {
        let text = try await transcribe(timeout: timeout, quiet: Self.sentenceQuiet, announces: true) { _, isFinal in
            isFinal
        }
        return Heard(text: text, button: ButtonLookup.button(for: text, in: map))
    }

    /// Listens for "next" on a plan, and returns whether it came before `timeout`.
    /// Whoever calls this has already finished saying "say next", so VoiceOver has
    /// nothing to announce here.
    func listenForNext(timeout: Duration = .seconds(60)) async throws -> Bool {
        let text = try await transcribe(timeout: timeout, quiet: nil, announces: false) { text, _ in
            NextWord.isIn(text)
        }
        return NextWord.isIn(text)
    }

    /// The last thing heard before `isDone` said to stop, `quiet` passed with no new
    /// words, or `timeout` passed. Silence before the first word never counts as quiet.
    private func transcribe(timeout: Duration, quiet: Duration?, announces: Bool,
                            until isDone: (String, Bool) -> Bool) async throws -> String {
        try Task.checkCancellation()
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation()
        guard allowed else { throw VoiceRequestError.permissionDenied }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        else { throw VoiceRequestError.unavailable }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        if announces { try await announceListening() }
        try Task.checkCancellation()
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw VoiceRequestError.noMicrophone }
        let input = try await CaptureInputSequenceProvider.providerWithSession(
            from: microphone, compatibleWith: [transcriber]
        )
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(inputSequence: input.analyzerInputs, modules: [transcriber])
        input.captureSession.startRunning()
        defer { input.captureSession.stopRunning() }

        // Stop listening at the time limit, after the quiet, or as soon as this
        // task is cancelled; any of these ends the results below.
        let timedOut = Mutex(false)
        let lastWords = Mutex<ContinuousClock.Instant?>(nil)
        let deadline = Task {
            let end = ContinuousClock.now.advanced(by: timeout)
            do {
                while ContinuousClock.now < end {
                    try await Task.sleep(for: .milliseconds(100))
                    if let quiet, let last = lastWords.withLock({ $0 }), last.duration(to: .now) >= quiet { break }
                }
                timedOut.withLock { $0 = true }
            } catch { /* Cancelling the request also ends the analyzer. */ }
            await analyzer.cancelAndFinishNow()
        }
        defer { deadline.cancel() }

        var heard = ""
        do {
            try await withTaskCancellationHandler {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    heard = text
                    lastWords.withLock { $0 = .now }
                    if isDone(text, result.isFinal) { break }
                }
            } onCancel: {
                deadline.cancel()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            try Task.checkCancellation()
            // Only a deadline is an expected recognition failure. Device and
            // recognizer errors must reach the launch screen's retry message.
            if !timedOut.withLock({ $0 }) { throw error }
        }
        await analyzer.cancelAndFinishNow()
        try Task.checkCancellation()
        return heard
    }

    /// Finish VoiceOver's prompt before opening the microphone so recognition
    /// cannot mistake our own instructions for the user's button name.
    @MainActor
    private func announceListening() async throws {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let message = "Listening. Say a button name after this announcement."
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { notification in
            if notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String == message {
                pair.continuation.yield(())
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            pair.continuation.finish()
        }
        // VoiceOver can be disabled or interrupted while the prompt is speaking.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(6))
            pair.continuation.yield(())
        }
        defer { timeout.cancel() }
        UIAccessibility.post(notification: .announcement, argument: message)
        for await _ in pair.stream { break }
        try Task.checkCancellation()
    }

}
