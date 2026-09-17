//
//  HarnessApp.swift
//  Harness
//
//  Experience's blindfold rig. Runs on a Mac, needs no iPhone and no camera.
//  Owned by the Outcome Signals & Harness lane.
//
//  Move the sliders, pick a tracking quality, fire an outcome — the rig builds
//  a TrackingFrame, turns it into a GuidanceState, and hands it to whatever
//  FeedbackEngine is injected below. Swap `PrintingFeedbackEngine()` for
//  `LiveFeedbackEngine()` the day Experience has something to feel.
//

import ContourMocks
import SwiftUI

@main
struct HarnessApp: App {

    // ── INJECTION POINT ──────────────────────────────────────────────────────
    // This is the one line Experience edits. Everything downstream is the contract.
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
