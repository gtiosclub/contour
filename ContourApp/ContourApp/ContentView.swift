//
//  ContentView.swift
//  ContourApp — Experience / Accessibility & Launch
//
//  The app's root: it launches straight into the camera. Point at a panel →
//  Scan → say (or pick) a button → guidance → outcome. VoiceOver-first: every
//  stage change is announced by ContourUI's GuidanceFlow, and each screen's
//  most important action is also the Magic Tap.
//
//  The screens are ContourUI's (they take plain data and closures); the
//  decisions are ExperienceModel's; this view only picks the screen for the
//  stage and hands each one the camera preview, which lives in the app.
//
//  DEVELOPER TOOLS (DEBUG only): the ladybug in the top-right corner opens
//  Debug/DebugMenu.swift — pipeline status, manual tracking test, captured
//  panel review, tracking diagnostics and the rest. None of it is in the flow.
//
//  SCREENSHOTS / DEMOS (DEBUG only): launch with
//      -ContourDemoStage acquire | detecting | select | guide
//                      | arrived | lostTracking | notFound | lowConfidence
//  to open on that stage with the mock six-button microwave (see DemoStage in
//  Experience/ExperienceSupport.swift). The Simulator runs the mock pipeline
//  with no camera, so the viewfinder shows a drawn panel instead.
//

import ContourCore
import ContourMocks
import ContourUI
import SwiftUI

struct ContentView: View {

    let pipeline: ContourPipeline
    /// Shared with the pipeline, so live tracking follows the camera you aim.
    let camera: CameraService

    @State private var model: ExperienceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var showDebugMenu = false
    #endif

    init(pipeline: ContourPipeline, camera: CameraService) {
        self.pipeline = pipeline
        self.camera = camera
        _model = State(initialValue: ExperienceModel(pipeline: pipeline, camera: camera))
    }

    var body: some View {
        #if DEBUG
        NavigationStack {
            flow
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showDebugMenu = true } label: {
                            Image(systemName: "ladybug")
                        }
                        .accessibilityLabel("Developer tools")
                        .accessibilityHint("Opens the debug menu. Debug builds only.")
                    }
                }
        }
        .sheet(isPresented: $showDebugMenu, onDismiss: { model.resumeAfterDebugTools() }) {
            NavigationStack {
                DebugMenu(pipeline: pipeline, camera: camera)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDebugMenu = false }
                        }
                    }
            }
        }
        .onChange(of: showDebugMenu) { _, showing in
            if showing { model.pauseForDebugTools() }
        }
        #else
        flow
        #endif
    }

    private var flow: some View {
        screen
            .animation(ContourTheme.Motion.stageChange(reduceMotion: reduceMotion), value: model.stage.kind)
            .preferredColorScheme(.dark)
            .task { await model.run() }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(isActive: phase == .active)
            }
            .onChange(of: pipeline.latestGuidance) { _, _ in
                model.guidanceChanged()
            }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.stage {
        case .idle, .acquiringPanel: acquire
        case .detecting: detecting
        case .selectingTarget(let map): select(map)
        case .guiding(let target): guide(target)
        case .finished(let outcome): finished(outcome)
        }
    }

    private var acquire: some View {
        AcquireScreen(message: model.message ?? model.cameraError, isCapturing: model.isCapturing,
                      onScan: { model.scan() }) {
            viewfinder(highlighting: nil)
        }
        .transition(.opacity)
    }

    private var detecting: some View {
        DetectingScreen(photo: model.photo, sample: model.usesCamera ? nil : DemoPanel.map,
                        onCancel: { model.cancelScan() }) {
            viewfinder(highlighting: nil)
        }
        .transition(.opacity)
    }

    private func select(_ map: SurfaceMap) -> some View {
        SelectScreen(map: map, photo: model.photo, quad: model.quad,
                     canListen: model.selection.canListen, isListening: model.isListening,
                     heard: model.heard, message: model.message,
                     onChoose: { model.choose($0) }, onSay: { model.sayAButton() },
                     onRescan: { model.rescan() })
        .transition(.opacity)
    }

    private func guide(_ target: SurfaceMap.Button) -> some View {
        GuideScreen(target: target, targetName: model.targetName, guidance: model.guidance,
                    onStop: { model.stopGuiding() }) {
            viewfinder(highlighting: target)
        }
        .transition(.opacity)
    }

    private func finished(_ outcome: OutcomeSignal) -> some View {
        let guideAgain: (() -> Void)? = model.canGuideAgain ? { model.guideAgain() } : nil
        let chooseAnother: (() -> Void)? = model.map == nil ? nil : { model.chooseAnother() }
        return OutcomeScreen(outcome: outcome, targetName: model.targetName, detail: model.outcomeDetail,
                             onGuideAgain: guideAgain, onChooseAnother: chooseAnother,
                             onScanNew: { model.rescan() })
        .transition(.opacity)
    }

    /// The live camera when the pipeline uses it and it started; otherwise a
    /// drawn stand-in, so the Simulator and screenshots still read as "camera".
    @ViewBuilder
    private func viewfinder(highlighting target: SurfaceMap.Button?) -> some View {
        if model.usesCamera && model.cameraError == nil {
            CameraPreview(session: camera.session)
        } else {
            let sample = model.usesCamera ? nil : (model.map ?? DemoPanel.map)
            ViewfinderPlaceholder(
                sample: sample,
                message: model.cameraError ?? DemoPanel.noCameraMessage,
                highlightedID: target?.id,
                fingertip: target.flatMap {
                    ExperiencePolicy.approximateFingertip(target: $0, guidance: model.guidance)
                }
            )
        }
    }
}

/// What the viewfinder shows when the mock pipeline runs without a camera.
private enum DemoPanel {
    static let map = MockSurfaceMaps.microwave
    static var noCameraMessage: String {
        #if targetEnvironment(simulator)
        "Camera unavailable in Simulator"
        #else
        "Camera not in use: Surface Understanding is mocked"
        #endif
    }
}

#Preview {
    ContentView(pipeline: .mock(), camera: CameraService())
}
