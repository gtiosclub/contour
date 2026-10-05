//
//  HarnessApp.swift
//  Harness
//
//  Experience's blindfold rig. Runs on a Mac and sends synthetic guidance to iPhone.
//  Owned by the Outcome Signals & Harness lane.
//
//  Move the sliders, pick a tracking quality, fire an outcome — the rig builds
//  a TrackingFrame, turns it into a GuidanceState, and hands it to whatever
//  remote FeedbackEngine is injected below. Physical feedback is rendered on iPhone.
//

import SwiftUI

@main
struct HarnessApp: App {

    // Share one connection between the model's FeedbackEngine and the UI.
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: HarnessConnection
    @State private var model: HarnessModel

    init() {
        let connection = HarnessConnection()
        _connection = State(initialValue: connection)
        _model = State(initialValue: HarnessModel(engine: connection))
    }

    var body: some Scene {
        WindowGroup("Contour Harness") {
            HarnessView(model: model)
                .environment(connection)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .background { connection.stop() }
                    else if phase == .active {
                        connection.start()
                        model.emit()
                    }
                }
        }
        .defaultSize(width: 560, height: 720)
    }
}
