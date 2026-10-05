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

import SwiftUI

@main
struct ContourApp: App {

    // On a phone, Surface Understanding runs for real on camera frames. The
    // simulator has no camera, so it stays fully mocked.
    #if targetEnvironment(simulator)
    @State private var pipeline = ContourPipeline.mock()
    #else
    @State private var pipeline = ContourPipeline.realPanel()
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView(pipeline: pipeline)
        }
    }
}
