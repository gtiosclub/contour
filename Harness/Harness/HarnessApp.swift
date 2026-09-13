//
//  HarnessApp.swift
//  Harness
//
//  Team 3's blindfold rig. Runs on a Mac, needs no iPhone and no camera.
//
//  Move the sliders, pick a tracking quality, fire an outcome — the rig builds
//  a TrackingFrame, turns it into a GuidanceState, and hands it to whatever
//  FeedbackEngine is injected below. Swap `PrintingFeedbackEngine()` for
//  `LiveFeedbackEngine()` the day Team 3 has something to feel.
//

import ContourMocks
import SwiftUI

@main
struct HarnessApp: App {

    // ── INJECTION POINT ──────────────────────────────────────────────────────
    // This is the one line Team 3 edits. Everything downstream is the contract.
    //
    //   import ContourFeedback
    //   @State private var model = HarnessModel(engine: LiveFeedbackEngine())
    //
    @State private var model = HarnessModel(engine: PrintingFeedbackEngine())
    // ─────────────────────────────────────────────────────────────────────────

    var body: some Scene {
        WindowGroup("Contour Harness") {
            HarnessView(model: model)
        }
        .defaultSize(width: 560, height: 720)
    }
}
