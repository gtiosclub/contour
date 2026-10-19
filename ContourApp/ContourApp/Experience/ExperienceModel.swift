//
//  ExperienceModel.swift
//  ContourApp — Experience / Accessibility & Launch
//
//  Drives ContourUI's GuidanceFlow from real actions: the shared camera, the
//  pipeline's detection and guidance, and the voice request. Wiring, not
//  features — the stages, words and screens are ContourUI's; detection and
//  tracking are the pipeline's.
//
//  CANCELLATION
//  Same rules ContentView's scaffold had: every long-running action has an ID,
//  a newer action cancels the older one, and a task whose ID is no longer
//  current changes nothing when it finishes. The pipeline's own generation
//  check stops a superseded scan or guidance session underneath.
//

import ContourCore
import ContourMocks
import ContourUI
import Foundation
import Observation

@Observable
final class ExperienceModel {

    let pipeline: ContourPipeline
    let camera: CameraService

    @ObservationIgnored let flow: GuidanceFlow
    @ObservationIgnored let selection: TargetSelection
    @ObservationIgnored private let capture: CaptureFlow
    @ObservationIgnored private let announcer: SpokenAnnouncer
    private let transcript: Transcript

    /// The stage on screen, following `flow.stages()`.
    private(set) var stage: GuidanceFlowStage = .idle
    /// The photo being read, or that was read.
    private(set) var photo: PanelPhoto?
    /// What Surface read from it.
    private(set) var map: SurfaceMap?
    /// The control being guided to, or last guided to.
    private(set) var target: SurfaceMap.Button?
    /// An error or hint, shown on the current screen and spoken.
    private(set) var message: String?
    /// Replaces the outcome screen's default message (what was heard).
    private(set) var outcomeDetail: String?
    /// Why guidance can't go on — tracking couldn't lock onto the panel. The
    /// guide screen shows it and offers Scan again.
    private(set) var trackingProblem: String?
    private(set) var isCapturing = false
    private(set) var isListening = false
    /// Why the live camera isn't showing, if it isn't.
    private(set) var cameraError: String?
    #if DEBUG
    /// A frozen guidance state for `-ContourDemoStage guide`.
    private(set) var demoGuidance: GuidanceState?
    #endif

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var guidanceTask: Task<Void, Never>?
    @ObservationIgnored private var guidanceID: UUID?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var listenID: UUID?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var selectionID: UUID?
    @ObservationIgnored private var lostTimer: Task<Void, Never>?

    init(pipeline: ContourPipeline, camera: CameraService) {
        self.pipeline = pipeline
        self.camera = camera
        let announcer = SpokenAnnouncer()
        let transcript = Transcript()
        self.announcer = announcer
        self.transcript = transcript
        // LiveFeedbackEngine already speaks the outcomes that guidance ends
        // in, so the flow stays quiet for those rather than saying them twice.
        let spokenByFeedback: Set<String> = pipeline.liveComponents.contains(.feedback)
            ? [GuidanceFlow().announcement(for: .finished(.arrived)),
               GuidanceFlow().announcement(for: .finished(.lostTracking))]
            : []
        self.flow = GuidanceFlow { text in
            guard !spokenByFeedback.contains(text) else { return }
            await announcer.say(text, interrupt: true)
        }
        let usesCamera = pipeline.liveComponents.contains(.surfaceUnderstanding)
        self.capture = CaptureFlow {
            // The mock ignores the photo entirely, so it gets a zero-byte one;
            // live Surface gets a frame from the camera Tracking also follows.
            guard usesCamera else {
                return PanelPhoto(data: Data(), pixelSize: PixelSize(width: 4032, height: 3024), timestamp: Date())
            }
            return try await camera.capturePanelPhoto()
        }
        self.selection = TargetSelection { @MainActor map in
            let heard = try await VoiceRequest().listen(for: map)
            transcript.record(heard.text)
            return heard.button
        }
    }

    // MARK: Derived

    /// Whether scans use the camera. The mock pipeline needs no photo.
    var usesCamera: Bool { pipeline.liveComponents.contains(.surfaceUnderstanding) }

    /// What was heard last, for the selection screen.
    var heard: String? {
        transcript.text.map { $0.isEmpty ? "Didn't hear anything." : "Heard \u{201C}\($0)\u{201D}" }
    }

    /// The live guidance to draw.
    var guidance: GuidanceState? {
        #if DEBUG
        if let demoGuidance { return demoGuidance }
        #endif
        return pipeline.latestGuidance
    }

    /// The panel's outline in the photo, so the overlay lands on the panel.
    var quad: PanelQuad? {
        guard let reference = pipeline.panelReference, reference.photo.id == photo?.id else { return nil }
        return reference.detection.quad
    }

    var targetName: String? {
        guard let target else { return nil }
        if let map, let entry = PanelLayout(map: map).entry(for: target.id) {
            return PanelLayout(map: map).title(for: entry)
        }
        return PanelLayout.spokenName(for: target)
    }

    var canGuideAgain: Bool { target != nil && map != nil }

    // MARK: Lifecycle

    /// Runs for as long as the flow is on screen: follows the stages and
    /// starts at the camera.
    func run() async {
        let stages = flow.stages()
        #if DEBUG
        if let demo = DemoStage.fromLaunchArguments() {
            await applyDemo(demo)
        } else {
            await begin()
        }
        #else
        await begin()
        #endif
        for await stage in stages { self.stage = stage }
    }

    private func begin() async {
        startCameraIfNeeded()
        if await flow.currentStage() == .idle { await flow.advance(to: .acquiringPanel) }
    }

    func scenePhaseChanged(isActive: Bool) {
        if isActive {
            Task { await begin() }
            return
        }
        // Leaving the app ends anything running, as the scaffold did. A screen
        // that is only waiting (aiming, choosing, an outcome) stays put.
        stopRunningWork()
        Task {
            await pipeline.stopGuidance()
            await camera.stop()
            switch await flow.currentStage() {
            case .detecting, .guiding: await flow.cancel()
            default: break
            }
        }
    }

    /// The debug menu is opening: stand down so its tools have the pipeline
    /// and the camera to themselves.
    func pauseForDebugTools() {
        stopRunningWork()
        endSelection()
        message = nil
        trackingProblem = nil
        Task {
            await pipeline.stopGuidance()
            await flow.cancel()
        }
    }

    /// The debug menu closed. Its tools may have replaced the panel, so start
    /// again from the camera.
    func resumeAfterDebugTools() {
        #if DEBUG
        demoGuidance = nil
        #endif
        Task { await begin() }
    }

    private func startCameraIfNeeded() {
        guard usesCamera else { return }
        Task {
            do {
                try await camera.start()
                cameraError = nil
            } catch {
                guard cameraError != error.localizedDescription else { return }
                cameraError = error.localizedDescription
                await announcer.say(error.localizedDescription, interrupt: false)
            }
        }
    }

    // MARK: Scan

    func scan() {
        stopRunningWork()
        endSelection()
        message = nil
        outcomeDetail = nil
        trackingProblem = nil
        transcript.text = nil
        let id = UUID()
        scanID = id
        isCapturing = true
        scanTask = Task {
            defer {
                if scanID == id {
                    scanTask = nil
                    isCapturing = false
                }
            }
            do {
                await pipeline.stopGuidance()
                if await flow.currentStage() == .idle { await flow.advance(to: .acquiringPanel) }
                try Task.checkCancellation()
                let photo = try await capture.capturePanelPhoto()
                guard scanID == id, !Task.isCancelled else { return }
                self.photo = photo
                map = nil
                target = nil
                isCapturing = false
                guard await flow.advanceIfLegal(to: .detecting) else { return }
                let started = ContinuousClock.now
                let detected = try await pipeline.detectPanel(in: photo)
                try await Task.sleep(until: started + ExperiencePolicy.minimumDetectingTime)
                guard scanID == id, !Task.isCancelled else { return }
                await finishScan(detected)
            } catch is CancellationError {
                // A newer scan, Cancel, or leaving the app ended this one.
            } catch {
                guard scanID == id else { return }
                await failScan(error.localizedDescription)
            }
        }
    }

    private func finishScan(_ detected: SurfaceMap) async {
        map = detected
        switch ExperiencePolicy.scanResult(map: detected, canGuide: pipeline.canGuide) {
        case .select:
            await showSelection(detected)
        case .retry(let reason):
            await failScan(reason)
        case .lowConfidence:
            await flow.advance(to: .finished(.lowConfidence))
        }
    }

    private func failScan(_ reason: String) async {
        await flow.advance(to: .acquiringPanel)
        await show(reason)
    }

    /// Cancel on the detecting screen: back to aiming.
    func cancelScan() {
        stopRunningWork()
        Task {
            await pipeline.stopGuidance()
            await flow.advance(to: .acquiringPanel)
        }
    }

    /// "Scan again" / "Scan a new panel": back to the camera.
    func rescan() {
        stopRunningWork()
        endSelection()
        message = nil
        outcomeDetail = nil
        trackingProblem = nil
        Task {
            await pipeline.stopGuidance()
            await flow.advance(to: .acquiringPanel)
            startCameraIfNeeded()
        }
    }

    // MARK: Select

    private func showSelection(_ map: SurfaceMap) async {
        guard await flow.advanceIfLegal(to: .selectingTarget(map)) else { return }
        endSelection()
        let id = UUID()
        selectionID = id
        selectionTask = Task {
            let chosen = await selection.selectTarget(in: map)
            guard selectionID == id, !Task.isCancelled else { return }
            selectionTask = nil
            selectionID = nil
            // nil: backed out — whoever backed out has already moved the flow.
            if let chosen { await startGuidance(to: chosen) }
        }
    }

    /// A row or a control on the photo was tapped.
    func choose(_ button: SurfaceMap.Button) {
        if !selection.choose(button) {
            // Nothing awaiting (e.g. a demo stage): guide directly.
            Task { await startGuidance(to: button) }
        }
    }

    /// "Say a button": listen once; a match guides, anything else is notFound.
    func sayAButton() {
        guard selection.canListen, listenTask == nil, let map else { return }
        let rearm = !selection.broker.isAwaiting
        message = nil
        transcript.text = nil
        isListening = true
        let id = UUID()
        listenID = id
        listenTask = Task {
            defer {
                if listenID == id {
                    listenTask = nil
                    listenID = nil
                    isListening = false
                }
            }
            do {
                if rearm {
                    // Nothing is waiting for a choice (e.g. after a demo jump):
                    // wait again, and give that a moment to register.
                    await showSelectionAgain(map)
                    for _ in 0..<50 where !selection.broker.isAwaiting {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                let matched = try await selection.listenForTarget()
                guard listenID == id, !Task.isCancelled else { return }
                if matched != nil { return }   // the selection task guides from here
                let said = transcript.text ?? ""
                if said.isEmpty {
                    await show("Didn't hear anything. Tap Say a button, then say the button's name.")
                    return
                }
                outcomeDetail = "There's no \u{201C}\(said)\u{201D} on this panel. Choose another button, or scan again."
                endSelection()
                await flow.advance(to: .finished(.notFound))
            } catch is CancellationError {
                // Choosing by touch, scanning again or leaving ended the request.
            } catch {
                guard listenID == id else { return }
                await show(error.localizedDescription)
            }
        }
    }

    private func showSelectionAgain(_ map: SurfaceMap) async {
        if case .selectingTarget = await flow.currentStage() {
            endSelection()
            let id = UUID()
            selectionID = id
            selectionTask = Task {
                let chosen = await selection.selectTarget(in: map)
                guard selectionID == id, !Task.isCancelled else { return }
                selectionTask = nil
                selectionID = nil
                if let chosen { await startGuidance(to: chosen) }
            }
        } else {
            await showSelection(map)
        }
    }

    // MARK: Guide

    private func startGuidance(to button: SurfaceMap.Button) async {
        listenTask?.cancel()
        guard pipeline.canGuide else {
            await show("Surface did not return a trackable panel outline. Scan again, showing the full panel.")
            return
        }
        target = button
        outcomeDetail = nil
        trackingProblem = nil
        #if DEBUG
        demoGuidance = nil
        #endif
        guard await flow.advanceIfLegal(to: .guiding(button)) else { return }
        guidanceTask?.cancel()
        let id = UUID()
        guidanceID = id
        guidanceTask = Task {
            await pipeline.guide(to: button)
            guard guidanceID == id else { return }
            guidanceTask = nil
            guidanceID = nil
            lostTimer?.cancel()
            guard !Task.isCancelled else { return }
            let outcome = ExperiencePolicy.outcome(afterGuidanceEndedWith: pipeline.lastOutcome)
            await flow.advance(to: .finished(outcome))
        }
    }

    /// The pipeline presented a new guidance state. A loss that lasts ends the
    /// session; a brief one recovers on its own.
    func guidanceChanged() {
        // The error may be the same text as last session's, which onChange
        // wouldn't report again; check it with every new state as well.
        trackingErrorChanged()
        guard trackingProblem == nil, pipeline.latestGuidance?.outcome == .lostTracking, let id = guidanceID else {
            lostTimer?.cancel()
            lostTimer = nil
            return
        }
        guard lostTimer == nil else { return }
        lostTimer = Task {
            try? await Task.sleep(for: ExperiencePolicy.lostTrackingTimeout)
            guard !Task.isCancelled, guidanceID == id,
                  pipeline.latestGuidance?.outcome == .lostTracking else { return }
            lostTimer = nil
            guidanceTask?.cancel()
            guidanceTask = nil
            guidanceID = nil
            await pipeline.stopGuidance()
            await flow.advance(to: .finished(.lostTracking))
        }
    }

    /// Tracking reported (or cleared) an error. If it can't lock onto the
    /// panel while guiding, waiting won't help: stop guidance and stay on the
    /// guide screen, which says so and offers Scan again.
    func trackingErrorChanged() {
        guard let problem = ExperiencePolicy.trackingProblem(for: pipeline.trackingError),
              guidanceID != nil, trackingProblem == nil else { return }
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
        lostTimer?.cancel()
        lostTimer = nil
        trackingProblem = problem
        Task {
            await pipeline.stopGuidance()
            // A newer session or Scan again got there first.
            guard guidanceID == nil, trackingProblem == problem else { return }
            await announcer.say(problem, interrupt: true)
        }
    }

    /// Stop, while guiding: back to the controls on the same panel.
    func stopGuiding() {
        stopRunningWork()
        trackingProblem = nil
        #if DEBUG
        demoGuidance = nil
        #endif
        Task {
            await pipeline.stopGuidance()
            if let map { await showSelection(map) } else { await flow.advance(to: .acquiringPanel) }
        }
    }

    /// "Guide again", from an outcome.
    func guideAgain() {
        guard let target else { return }
        Task { await startGuidance(to: target) }
    }

    /// "Choose another button", from an outcome.
    func chooseAnother() {
        guard let map else { return }
        outcomeDetail = nil
        Task { await showSelection(map) }
    }

    // MARK: Helpers

    /// Ends scanning, guidance and listening. Leaves the selection waiting.
    /// Callers that need the pipeline quiet too await `stopGuidance()` — not
    /// spawned here, so it can never race a scan that has just started.
    private func stopRunningWork() {
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
        isCapturing = false
        guidanceTask?.cancel()
        guidanceTask = nil
        guidanceID = nil
        listenTask?.cancel()
        listenTask = nil
        listenID = nil
        isListening = false
        lostTimer?.cancel()
        lostTimer = nil
    }

    /// Ends a waiting selection without choosing.
    private func endSelection() {
        selectionTask?.cancel()
        selectionTask = nil
        selectionID = nil
        selection.backOut()
    }

    /// Shows `text` on the current screen and says it after the stage's own line.
    private func show(_ text: String) async {
        message = text
        await announcer.say(text, interrupt: false)
    }

    #if DEBUG
    /// Walks the flow to `demo` through legal moves, with the mock microwave.
    private func applyDemo(_ demo: DemoStage) async {
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 4032, height: 3024),
                               timestamp: MockTrackingSource.fixedEpoch)
        // Prime the pipeline so actions taken afterwards work for real. Live
        // Surface would try to read an empty photo, so only the mock is primed.
        if !usesCamera { _ = try? await pipeline.detectPanel(in: photo) }
        self.photo = photo
        map = DemoStage.map
        if demo.route.contains(where: { $0.kind == .guiding }) { target = DemoStage.target }
        if demo == .guide { demoGuidance = DemoStage.guidance }
        if demo == .notFound {
            outcomeDetail = "There's no \u{201C}pizza\u{201D} on this panel. Choose another button, or scan again."
        }
        for stage in demo.route { await flow.advance(to: stage) }
        if demo == .select { await showSelectionAgain(DemoStage.map) }
    }
    #endif
}

/// What the voice request heard, shared with TargetSelection's listen closure.
@Observable
final class Transcript {
    var text: String?
    func record(_ text: String) { self.text = text }
}
