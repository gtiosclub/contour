//
//  ContourApp.swift
//  ContourApp
//
//  Contour — GT iOS Club. See README.md.
//
//  This target is the only place the four teams' packages meet. It owns no
//  features: it constructs one implementation of each protocol and hands them
//  to the pipeline. If you are adding logic here, ask which package it belongs
//  in first.
//

import ContourFeedback
import SwiftUI

@main
@MainActor
struct ContourApp: App {

    @State private var pipeline = ContourPipeline.mock()

    init() {
        do {
            try AudioSessionConfig.configure()
        } catch {
            assertionFailure("Unable to configure Contour audio session: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pipeline: pipeline)
        }
    }
}
