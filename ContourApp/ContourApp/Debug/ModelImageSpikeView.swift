//
//  ModelImageSpikeView.swift
//  ContourApp — Debug
//
//  THE WEEK 1 QUESTION: can the on-device model see a picture?
//
//  Answer, from WWDC26 session 237 ("What's new in image understanding"):
//  image input arrived with the iOS 27 SDK, via `Attachment(image)` inside a
//  `Prompt { }` builder. iOS 26 is text-only.
//
//  So Button Detector is an iOS 27 feature. On iOS 26 the model can't see the
//  panel and the lane falls back to Vision-only candidate boxes. This screen
//  proves it on a real phone: tap the button, read the result.
//
//  Needs a physical iPhone 15 Pro or newer on iOS 27. Simulator: no model.
//
//  If the iOS 27 call site below doesn't compile against your SDK, the shape
//  is right but the spelling may differ — check `Attachment` in the
//  FoundationModels docs and fix the two marked lines. Don't rebuild the lane
//  around it.
//

import SwiftUI
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

struct ModelImageSpikeView: View {
    @State private var result = "Not run yet."
    @State private var running = false

    var body: some View {
        List {
            Section("Availability") {
                Text(availabilityDescription)
            }
            Section("Image check") {
                Button(running ? "Running…" : "Ask the model what's in a test image") {
                    Task { await run() }
                }
                .disabled(running)
                Text(result)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Model image spike")
    }

    private var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(iOS 27, *) {
            return "iOS 27+: image input should be available (Prompt + Attachment)."
        } else {
            return "iOS 26: model is text-only. Image input needs iOS 27."
        }
        #else
        return "FoundationModels not available on this platform."
        #endif
    }

    private func run() async {
        running = true
        defer { running = false }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            result = "Model unavailable: \(model.availability)"
            return
        }

        // A synthetic "panel": dark rectangle, three light buttons, one label.
        let image = Self.makeTestImage()

        if #available(iOS 27, *) {
            do {
                let session = LanguageModelSession()
                // ── iOS 27 image call site ──────────────────────────────────
                let prompt = Prompt {
                    "This is a photo of an appliance control panel. How many buttons are on it, and what text is printed on them? Answer in one sentence."
                    Attachment(image)                       // ← if this line fails to compile, check the Attachment init in the iOS 27 SDK
                }
                let response = try await session.respond(to: prompt)
                // ───────────────────────────────────────────────────────────
                result = "iOS 27 image prompt worked.\n\n\(response.content)"
            } catch {
                result = "iOS 27 image prompt threw: \(error)"
            }
        } else {
            // Text-only sanity check so the screen still proves the model runs.
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: "Reply with the single word OK.")
                result = "Model runs, but this is iOS 26 — no image input. Text reply: \(response.content)"
            } catch {
                result = "Text prompt threw: \(error)"
            }
        }
        #else
        result = "FoundationModels not available."
        #endif
    }

    /// 600×400, dark panel, three light buttons, "START" on the last one.
    private static func makeTestImage() -> UIImage {
        let size = CGSize(width: 600, height: 400)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.88, alpha: 1).setFill()
            for i in 0..<3 {
                ctx.fill(CGRect(x: 40 + i * 180, y: 140, width: 150, height: 120))
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 28),
                .foregroundColor: UIColor(white: 0.1, alpha: 1),
            ]
            ("START" as NSString).draw(at: CGPoint(x: 430, y: 182), withAttributes: attrs)
        }
    }
}
