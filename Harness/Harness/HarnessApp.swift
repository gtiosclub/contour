//
//  HarnessApp.swift
//  Harness
//
//  Experience's blindfold rig. Runs on a Mac, needs no iPhone and no camera.
//  Owned by the Outcome Signals & Harness lane.
//
//  Move the sliders, pick a tracking quality, fire an outcome — the rig builds
//  a TrackingFrame, turns it into a GuidanceState, and hands it to a
//  FeedbackEngine. The window's engine picker switches between the printing
//  mock and LiveFeedbackEngine (and its model and channels) without a code
//  change; the engine below is only what it starts with.
//

import ContourMocks
import SwiftUI

@main
struct HarnessApp: App {

    // ── STARTING ENGINE ──────────────────────────────────────────────────────
    // The picker in the window switches engines at runtime. To start on the
    // real one instead, inject it here:
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
