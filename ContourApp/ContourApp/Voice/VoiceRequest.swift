//
//  VoiceRequest.swift
//  ContourApp — Officers (integration)
//
//  "Say a button": listen on the device and, as soon as what's been said names
//  a button on the scanned panel, return it. Uses the same on-device speech
//  setup as LiveCameraView.
//

import AVFoundation
import ContourCore
import Foundation
import Speech
import UIKit

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

    /// Listens until something said names a button on `map`, or `timeout`
    /// passes. Checks as the words come in, so "start" returns as soon as it's
    /// heard rather than after a pause.
    func listen(for map: SurfaceMap, timeout: Duration = .seconds(8)) async throws -> Heard {
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

        try await announceListening()
        try Task.checkCancellation()
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw VoiceRequestError.noMicrophone }
        let input = try await CaptureInputSequenceProvider.providerWithSession(
            from: microphone, compatibleWith: [transcriber]
        )
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(inputSequence: input.analyzerInputs, modules: [transcriber])
        input.captureSession.startRunning()
        defer { input.captureSession.stopRunning() }

        // Stop listening at the time limit, or as soon as this task is
        // cancelled; either ends the results below.
        var timedOut = false
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                timedOut = true
            } catch { /* Cancelling the request also ends the analyzer. */ }
            await analyzer.cancelAndFinishNow()
        }
        defer { deadline.cancel() }

        var heard = Heard(text: "", button: nil)
        do {
            try await withTaskCancellationHandler {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    heard.text = text
                    if let button = ButtonLookup.button(for: text, in: map) {
                        heard.button = button
                        break
                    }
                }
            } onCancel: {
                deadline.cancel()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            try Task.checkCancellation()
            // Only a deadline is an expected recognition failure. Device and
            // recognizer errors must reach the launch screen's retry message.
            if !timedOut { throw error }
        }
        await analyzer.cancelAndFinishNow()
        try Task.checkCancellation()
        return heard
    }

    /// Finish VoiceOver's prompt before opening the microphone so recognition
    /// cannot mistake our own instructions for the user's button name.
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
