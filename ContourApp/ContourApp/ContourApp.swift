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

    /// One camera for the scan, the preview and live tracking.
    @State private var camera: CameraService
    @State private var pipeline: ContourPipeline

    init() {
        let camera = CameraService()
        _camera = State(initialValue: camera)
        // On a phone everything runs for real on the camera. The simulator has
        // no camera, so it stays fully mocked.
        #if targetEnvironment(simulator)
        _pipeline = State(initialValue: .mock())
        #else
        _pipeline = State(initialValue: .live(camera: camera))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pipeline: pipeline, camera: camera)
        }
    }
}
