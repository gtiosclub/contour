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

enum VoiceRequestError: LocalizedError {
    case unavailable, noMicrophone

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available on this device."
        case .noMicrophone: "No microphone is available."
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
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        else { throw VoiceRequestError.unavailable }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw VoiceRequestError.noMicrophone }
        let input = try await CaptureInputSequenceProvider.providerWithSession(
            from: microphone, compatibleWith: [transcriber]
        )
        let analyzer = SpeechAnalyzer(inputSequence: input.analyzerInputs, modules: [transcriber])
        input.captureSession.startRunning()
        defer { input.captureSession.stopRunning() }

        // Stop listening at the time limit; that ends the results below.
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            await analyzer.cancelAndFinishNow()
        }
        defer { deadline.cancel() }

        var heard = Heard(text: "", button: nil)
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                heard.text = text
                if let button = ButtonLookup.button(for: text, in: map) {
                    heard.button = button
                    break
                }
            }
        } catch {
            // The analyzer stopping at the time limit can end the results with
            // an error; what was heard so far still stands.
        }
        await analyzer.cancelAndFinishNow()
        return heard
    }
}
