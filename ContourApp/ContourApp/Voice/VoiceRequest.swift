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
    /// Whoever calls this has already finished saying "say next", so there's
    /// nothing to announce here.
    func listenForNext(timeout: Duration = .seconds(60)) async throws -> Bool {
        let text = try await transcribe(timeout: timeout, quiet: nil, announces: false) { text, _ in
            NextWord.isIn(text)
        }
        return NextWord.isIn(text)
    }

    /// Asks for the microphone and fetches the speech model now, so the first
    /// request doesn't stop for an alert or a download in the middle of a plan.
    /// If anything fails here, the request tries again and says what went wrong.
    static func prepare() async {
        _ = try? await transcriber()
    }

    /// Microphone permission, then the on-device English model, downloaded if needed.
    private static func transcriber() async throws -> SpeechTranscriber {
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
        return transcriber
    }

    /// The last thing heard before `isDone` said to stop, `quiet` passed with no new
    /// words, or `timeout` passed. Silence before the first word never counts as quiet.
    private func transcribe(timeout: Duration, quiet: Duration?, announces: Bool,
                            until isDone: (String, Bool) -> Bool) async throws -> String {
        try Task.checkCancellation()
        let transcriber = try await Self.transcriber()
        try Task.checkCancellation()
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw VoiceRequestError.noMicrophone }
        // The app's own audio setup, not the one a capture session picks for itself:
        // that one isn't undone afterwards, and could leave speech on the earpiece.
        // The session only records sound. ARKit keeps the camera.
        try AppAudioSession.activate()
        let session = AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        let input = try await CaptureInputSequenceProvider.provider(from: microphone, in: session,
                                                                    compatibleWith: [transcriber])
        let device = try AVCaptureDeviceInput(device: microphone)
        session.beginConfiguration()
        let added = session.canAddInput(device) && session.canAddOutput(input.captureAudioDataOutput)
        if added {
            session.addInput(device)
            session.addOutput(input.captureAudioDataOutput)
        }
        session.commitConfiguration()
        guard added else { throw VoiceRequestError.noMicrophone }
        // Last, so the microphone opens as soon as this is said, and a setup that
        // fails never says it's listening.
        if announces { try await announceListening() }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(inputSequence: input.analyzerInputs, modules: [transcriber])
        session.startRunning()
        defer { session.stopRunning() }
        // This blocks until the microphone runs or fails. A failure is said now,
        // not after the time limit as if nobody spoke.
        guard session.isRunning else {
            await analyzer.cancelAndFinishNow()
            throw VoiceRequestError.noMicrophone
        }

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

    /// Says it's listening out loud, with VoiceOver on or off, and returns once
    /// that's finished, so recognition can't take our own words for a button name.
    @MainActor
    private func announceListening() async throws {
        await Self.cue.speak("Listening. Say a button name.")
        try Task.checkCancellation()
    }

    /// Kept for the app's life, so the voice is loaded after the first request.
    private static let cue = PlanSpeaker()

}
