import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import SurfaceUnderstanding
import Testing
@testable import ContourApp

@MainActor
@Suite("Launch experience")
struct CameraLaunchTests {
    private func pipeline(tracking: any TrackingSource = LaunchArrivalFrames(),
                          surface: any ContourCore.SurfaceUnderstanding = MockSurfaceUnderstanding()) -> ContourPipeline {
        let epoch = ContinuousClock.now
        var tick = 0
        return ContourPipeline(surfaceUnderstanding: surface, tracking: tracking,
                        feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [], guidanceNow: {
                            defer { tick += 1 }
                            return epoch.advanced(by: .milliseconds(tick * 100))
                        })
    }

    /// Scans say what they found out loud now, so these models use a voice that
    /// says nothing instead of the real one.
    private func makeModel(_ pipeline: ContourPipeline,
                           listen: @escaping @MainActor (SurfaceMap) async throws -> VoiceRequest.Heard = { _ in
                               VoiceRequest.Heard(text: "", button: nil)
                           }) -> CameraLaunchModel {
        CameraLaunchModel(camera: CameraService(), pipeline: pipeline, listen: listen, speaker: QuietSpeaker())
    }

    /// A model whose voice is recorded, with VoiceOver on or off.
    private func speakingModel(_ pipeline: ContourPipeline, speaker: RecordingSpeaker, voiceOver: Bool = false,
                               warmingUp: Bool = false) -> CameraLaunchModel {
        CameraLaunchModel(camera: CameraService(), pipeline: pipeline, listen: { _ in VoiceRequest.Heard(text: "", button: nil) },
                          speaker: speaker, voiceOverRunning: { voiceOver }, warmingUp: { warmingUp })
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test("A failed automatic scan followed by a valid manual reference exposes its target immediately")
    func manualReferenceRecoversFailedScan() async throws {
        let pipeline = ContourPipeline(surfaceUnderstanding: FailingMenuSurface(),
            tracking: EmptyLaunchFrames(), feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [])
        let model = makeModel(pipeline)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(model.status == "That scan didn't work. Try again")
        #expect(model.error == nil)
        #expect(!model.hasSelectionContent)
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
        let reference = try PanelReference(photo: photo, detection: PanelDetection(
            referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
        await pipeline.replaceReference(with: reference)
        model.referenceChanged()
        #expect(model.hasSelectionContent)
        #expect(model.map?.buttons.count == 6)
        model.scan()
        await model.waitForWork()
        #expect(!model.hasSelectionContent)
        #expect(model.map == nil)
    }

    @Test("No panel found produces the correct spoken status")
    func noPanelFoundUsesSpokenStatus() async {
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(failure: .noPanelFound),
            tracking: EmptyLaunchFrames(),
            feedback: PrintingFeedbackEngine(isPrinting: false),
            liveComponents: []
        )
        let model = makeModel(pipeline)

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(model.status == "I can't see the panel. Point the phone at the control panel and scan again")
        #expect(model.error == nil)
    }

    @Test("Undecodable image produces the retry message")
    func undecodableImageUsesSpokenStatus() async {
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(failure: .undecodableImage),
            tracking: EmptyLaunchFrames(),
            feedback: PrintingFeedbackEngine(isPrinting: false),
            liveComponents: []
        )
        let model = makeModel(pipeline)

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(model.status == "That scan didn't work. Try again")
        #expect(model.error == nil)
    }

    @Test("Cancelled scans do not announce a failure")
    func cancelledScanDoesNotReportFailure() async {
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(failure: .cancelled),
            tracking: EmptyLaunchFrames(),
            feedback: PrintingFeedbackEngine(isPrinting: false),
            liveComponents: []
        )
        let model = makeModel(pipeline)

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(model.error == nil)
        #expect(model.status != "Unable to complete the request")
    }

    @Test("A scan without buttons produces the correct spoken status")
    func noButtonsUsesSpokenStatus() async {
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(
                map: SurfaceMap(buttons: [], confidence: 1)
            ),
            tracking: EmptyLaunchFrames(),
            feedback: PrintingFeedbackEngine(isPrinting: false),
            liveComponents: []
        )
        let model = makeModel(pipeline)

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(
            model.status ==
            "I can't find any buttons. Point the phone at the control panel"
        )
        #expect(model.error == nil)
    }

    @Test("Successful scans preserve the panel ready message")
    func successfulScanKeepsReadyStatus() async {
        let pipeline = pipeline()
        let model = makeModel(pipeline)

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        // What follows "Panel ready." depends on the panel's keys.
        #expect(model.status.hasPrefix("Panel ready."))
        #expect(model.error == nil)
    }

    @Test("Mock launch scans and a spoken target starts guidance")
    func spokenTarget() async throws {
        let pipeline = pipeline()
        let model = makeModel(pipeline) { map in
            VoiceRequest.Heard(text: "Start", button: map.button(labelled: "Start"))
        }
        await model.setActive(true).value
        #expect(model.ready)
        model.scan()
        await model.waitForWork()
        #expect(model.map?.buttons.count == 6)
        model.sayAButton()
        await model.waitForWork()
        #expect(pipeline.guidanceArrived)
        #expect(model.status == "Reached Start.")
        #expect(!model.busy)
    }

    @Test("Silence and unmatched speech leave the panel available for manual selection", arguments: ["", "defrost"])
    func retrySpeech(text: String) async {
        let model = makeModel(pipeline()) { _ in
            VoiceRequest.Heard(text: text, button: nil)
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await model.waitForWork()
        #expect(model.map != nil)
        #expect(!model.busy && !model.listening)
        #expect(model.status.contains(text.isEmpty ? "Didn't hear" : "No button matching"))
    }

    @Test("Manual selection handles an ended stream without announcing arrival")
    func endedStream() async throws {
        let model = makeModel(pipeline(tracking: EmptyLaunchFrames()))
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.choose(try #require(model.map?.buttons.first))
        await model.waitForWork()
        #expect(!model.pipeline.guidanceArrived)
        #expect(model.status.contains("Guidance ended"))
    }

    @Test("Recognition errors remain recoverable without discarding the panel, and say so out loud")
    func recognitionError() async throws {
        let speaker = SpokenLines()
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline(), listen: { _ in
            throw NSError(domain: "VoiceTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        }, speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        speaker.lines.removeAll()
        model.sayAButton()
        await model.waitForWork()
        #expect(model.error == "Microphone access denied")
        #expect(model.map != nil && !model.busy && !model.listening && model.ready)
        #expect(speaker.lines == ["Voice isn't available. Choose a button below."])
        #expect(model.status == "Voice isn't available. Choose a button below.")
        // Tapping a button still guides.
        model.choose(try #require(model.map?.button(labelled: "Start")))
        await model.waitForWork()
        #expect(model.status == "Reached Start.")
    }

    @Test("Replacing a panel cancels a pending voice selection")
    func changedReference() async throws {
        let gate = ListeningGate()
        let pipeline = pipeline()
        let model = makeModel(pipeline) { _ in
            gate.started()
            try await Task.sleep(for: .seconds(60))
            return VoiceRequest.Heard(text: "Start", button: MockSurfaceMaps.microwaveStartButton)
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await gate.waitForStart()
        _ = try await pipeline.detectPanel(in: PanelPhoto(data: Data(),
            pixelSize: PixelSize(width: 100, height: 100), timestamp: Date()))
        model.referenceChanged()
        await model.waitForWork()
        #expect(!model.listening && !model.guiding && !model.busy)
        #expect(model.status.contains("Panel ready"))
    }

    @Test("Backgrounding cancels listening and foregrounding allows another request")
    func cancelAndResume() async {
        let gate = ListeningGate()
        let model = makeModel(pipeline()) { _ in
            gate.started()
            try await Task.sleep(for: .seconds(60))
            return VoiceRequest.Heard(text: "", button: nil)
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await gate.waitForStart()
        await model.setActive(false).value
        #expect(!model.busy && !model.listening && !model.ready)
        await model.setActive(true).value
        #expect(model.ready && model.map != nil)
        model.scan()
        await model.waitForWork()
        #expect(model.map?.buttons.count == 6)
    }
    @Test("Launch selection uses the integrated feedback engine and confirmed dwell result")
    func integratedFeedback() async throws {
        let engine = LiveFeedbackEngine()
        engine.setChannels(audio: false, voice: false, haptics: false)
        let epoch = ContinuousClock.now
        var tick = 0
        let pipeline = ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(),
            tracking: LaunchArrivalFrames(), feedback: engine, liveComponents: [.feedback], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
        let model = makeModel(pipeline)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(model.ready && model.map != nil)
        model.choose(try #require(model.map?.button(labelled: "Start")))
        await model.waitForWork()
        #expect(pipeline.guidanceArrived && engine.didReachTarget)
        #expect(model.status == "Reached Start.")
        model.stop()
        #expect(!engine.didReachTarget, "Stopping must clear confirmation before async cleanup finishes")
        await model.waitForWork()
        #expect(!pipeline.guidanceArrived)
    }

    @Test("The ready message says whether every cook time can be guided, and what's missing")
    func readyStatus() {
        let choose = "Say a button name or choose one below."
        let advice = " If this panel has them, hold the phone about a foot away and scan again."
        func map(_ labels: String?...) -> SurfaceMap {
            SurfaceMap(buttons: labels.map { SurfaceMap.Button(label: $0, bounds: PanelRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 1) },
                       confidence: 1)
        }
        let all = map("Time Cook", "1", "2", "3", "0", "Start/Pause")
        #expect(CameraLaunchModel.readyStatus(for: all) == "Panel ready. Cook times ready. \(choose)")
        #expect(CameraLaunchModel.readyStatus(for: map("Start", "5"))
                == "Panel ready. \(choose) Cook times not ready, missing Time Cook and the number keys.\(advice)")
        // One stray digit used to hide that the cook times couldn't be guided.
        #expect(CameraLaunchModel.readyStatus(for: map("Time Cook", "1", "Start"))
                == "Panel ready. \(choose) Cook times not ready, missing \(["3", "0", "2"].formatted(.list(type: .and))).\(advice)")
        #expect(CameraLaunchModel.readyStatus(for: map("1", "2", "3", "0", "Start/Pause", "Express Cook"))
                == "Panel ready. \(choose) Cook times not ready, missing Time Cook.\(advice)")
        // Two of a key would be a guess, so the plan wouldn't use either.
        #expect(CameraLaunchModel.readyStatus(for: map("Time Cook", "Cook Time", "1", "2", "3", "0", "Start"))
                .contains("missing Time Cook."))
        #expect(CameraLaunchModel.readyStatus(for: map("Time Cook", "1", "2", "3", "0", "0", "Start"))
                .contains("missing 0."))
        // While the text model loads, aiming differently wouldn't help.
        #expect(CameraLaunchModel.readyStatus(for: map("Start", nil), warmingUp: true)
                == "Panel ready. \(choose) Cook times are still getting ready. Scan again in a moment.")
        #expect(CameraLaunchModel.readyStatus(for: all, warmingUp: true) == "Panel ready. Cook times ready. \(choose)")
    }

    @Test("A scan without the cook-time keys says so, and still does after leaving and coming back")
    func numberKeysWarning() async {
        // The mock panel has Start, but no Time Cook or digit keys.
        let model = makeModel(pipeline())
        await model.setActive(true).value
        #expect(!model.status.contains("Cook times"), "Nothing has been scanned yet")
        model.scan()
        await model.waitForWork()
        let missing = "Cook times not ready, missing Time Cook and the number keys."
        #expect(model.status.hasPrefix("Panel ready") && model.status.contains(missing))
        await model.setActive(false).value
        await model.setActive(true).value
        #expect(model.status.hasPrefix("Panel ready") && model.status.contains(missing))
    }

    // MARK: Hearing what a scan found

    @Test("Without VoiceOver, a scan says it's scanning and then what it found, once each")
    func scanSpeaksWithoutVoiceOver() async {
        let speaker = RecordingSpeaker()
        let model = speakingModel(pipeline(surface: ScanSequence([.success(everyKey)])), speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(speaker.spoken == [
            "Scanning panel. Hold the phone steady.",
            "Panel ready. Cook times ready. Say a button name or choose one below.",
        ])
        #expect(model.status == speaker.spoken.last)
    }

    @Test("With VoiceOver on, the app says nothing itself, so VoiceOver reads the status once")
    func scanQuietWithVoiceOver() async {
        let speaker = RecordingSpeaker()
        let model = speakingModel(pipeline(surface: ScanSequence([.success(everyKey)])), speaker: speaker, voiceOver: true)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(speaker.spoken.isEmpty)
        #expect(model.status == "Panel ready. Cook times ready. Say a button name or choose one below.")
        #expect(!model.speaksOwnStatus, "VoiceOver is left to read it")
    }

    @Test("Without VoiceOver, a failed scan is said too", arguments: [
        (Result<SurfaceMap, SurfaceUnderstandingError>.failure(.noPanelFound),
         "I can't see the panel. Point the phone at the control panel and scan again"),
        (.failure(.undecodableImage), "That scan didn't work. Try again"),
        (.success(SurfaceMap(buttons: [], confidence: 1)), "I can't find any buttons. Point the phone at the control panel"),
    ])
    func failureSpoken(answer: Result<SurfaceMap, SurfaceUnderstandingError>, line: String) async {
        let speaker = RecordingSpeaker()
        let model = speakingModel(pipeline(surface: ScanSequence([answer])), speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(speaker.spoken == ["Scanning panel. Hold the phone steady.", line])
        #expect(model.status == line && model.error == nil)
    }

    @Test("The buttons work while the result is said, and choosing one cuts it off before guiding")
    func choosingCutsOffTheResult() async throws {
        let speaker = RecordingSpeaker()
        speaker.held = "Panel ready"
        let model = speakingModel(pipeline(surface: ScanSequence([.success(everyKey)])), speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await until { speaker.isHolding }
        #expect(!model.busy && !model.scanning && model.hasSelectionContent)
        model.choose(try #require(model.map?.button(labelled: "Popcorn")))
        #expect(!speaker.isHolding)
        await model.waitForWork()
        #expect(speaker.spoken.count == 2, "Nothing else is said over the guidance")
        #expect(model.status == "Reached Popcorn." || model.status.hasPrefix("Guidance ended"))
    }

    @Test("Without VoiceOver, not hearing a button name is said out loud", arguments: ["", "defrost"])
    func unmatchedSpeechSpoken(text: String) async {
        let speaker = RecordingSpeaker()
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline(),
                                      listen: { _ in VoiceRequest.Heard(text: text, button: nil) },
                                      speaker: speaker, voiceOverRunning: { false })
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        model.sayAButton()
        await model.waitForWork()
        #expect(speaker.spoken.last == model.status)
        #expect(model.status.hasPrefix(text.isEmpty ? "Didn't hear" : "No button matching"))
        #expect(!model.busy)
    }

    // MARK: Scanning again by itself

    @Test("Missing cook-time keys: new photos until one has them, then it stops")
    func rescansUntilReady() async {
        let surface = ScanSequence([.success(missingTimeCook), .success(everyKey), .success(everyKey)])
        let model = makeModel(pipeline(surface: surface))
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(surface.photoIDs.count == 2)
        #expect(Set(surface.photoIDs).count == 2, "Every try is a new photo")
        #expect(model.pipeline.panelReference?.photo.id == surface.photoIDs.last)
        #expect(model.status == "Panel ready. Cook times ready. Say a button name or choose one below.")
    }

    @Test("At most three photos, and the best one stays as the panel, said once")
    func keepsTheBest() async {
        let speaker = RecordingSpeaker()
        let surface = ScanSequence([
            .success(missingStart), .success(SurfaceMap(buttons: [], confidence: 1)), .failure(.noPanelFound),
            .success(everyKey),
        ])
        let model = speakingModel(pipeline(surface: surface), speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(surface.photoIDs.count == 3)
        #expect(model.pipeline.panelReference?.photo.id == surface.photoIDs.first)
        #expect(model.map?.buttons.map(\.label) == missingStart.buttons.map(\.label))
        #expect(model.hasSelectionContent)
        #expect(model.status.contains("missing Start."))
        #expect(speaker.spoken == ["Scanning panel. Hold the phone steady.", model.status])
    }

    @Test("While the text model loads, one photo, and it says to wait instead of how to aim")
    func noRetryWhileWarmingUp() async {
        let surface = ScanSequence([.success(MockSurfaceMaps.microwave)])
        let model = speakingModel(pipeline(surface: surface), speaker: RecordingSpeaker(), warmingUp: true)
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        #expect(surface.photoIDs.count == 1)
        #expect(model.status
                == "Panel ready. Say a button name or choose one below. Cook times are still getting ready. Scan again in a moment.")
    }

    @Test("Stop and going to the background end the tries, and nothing more is said", arguments: [false, true])
    func stopEndsTheTries(background: Bool) async {
        let surface = ScanSequence([.success(MockSurfaceMaps.microwave)], latency: .milliseconds(300))
        let speaker = RecordingSpeaker()
        let model = speakingModel(pipeline(surface: surface), speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await until { surface.photoIDs.count == 1 }
        if background { await model.setActive(false).value } else { model.stop() }
        await model.waitForWork()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(surface.photoIDs.count == 1)
        #expect(!model.busy && !model.scanning)
        #expect(speaker.spoken == ["Scanning panel. Hold the phone steady."])
        if !background { #expect(model.status.hasPrefix("Stopped")) }
    }

    @Test("The user's Stop is said once, by the app only without VoiceOver, and a stopped scan says to scan again",
          arguments: [false, true])
    func stopIsSaid(voiceOver: Bool) async {
        let surface = ScanSequence([.success(MockSurfaceMaps.microwave)], latency: .milliseconds(300))
        let speaker = RecordingSpeaker()
        let model = speakingModel(pipeline(surface: surface), speaker: speaker, voiceOver: voiceOver)
        await model.setActive(true).value
        model.scan()
        await until { surface.photoIDs.count == 1 }
        model.stop(aloud: true)
        await model.waitForWork()
        #expect(model.status == "Stopped. Scan the panel again.")
        #expect(!model.busy && !model.listening && !model.speaksOwnStatus, "VoiceOver reads the status")
        #expect(speaker.spoken == (voiceOver ? [] : ["Scanning panel. Hold the phone steady.", "Stopped. Scan the panel again."]))
    }

    @Test("The buttons work while Stop is said, and the next tap cuts it off")
    func tapCutsOffStop() async {
        let surface = ScanSequence([.success(MockSurfaceMaps.microwave)], latency: .milliseconds(300))
        let speaker = RecordingSpeaker()
        speaker.held = "Stopped"
        let model = speakingModel(pipeline(surface: surface), speaker: speaker)
        await model.setActive(true).value
        model.scan()
        await until { surface.photoIDs.count == 1 }
        model.stop(aloud: true)
        await until { speaker.isHolding }
        #expect(!model.busy)
        model.scan()
        #expect(!speaker.isHolding)
        model.stop()
        await model.waitForWork()
        #expect(Array(speaker.spoken.prefix(2)) == ["Scanning panel. Hold the phone steady.", "Stopped. Scan the panel again."])
    }

    @Test("The best photo: one that can guide, then the cook-time keys, then more buttons")
    func ranking() throws {
        typealias Attempt = CameraLaunchModel.ScanAttempt
        func beats(_ a: Attempt, _ b: Attempt) -> Bool { a.rank > b.rank }
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
        let reference = try PanelReference(photo: photo, detection: PanelDetection(
            referencePhotoID: photo.id, quad: .fullFrame, map: MockSurfaceMaps.microwave))
        let outline = Attempt(reference: reference, guidable: true, missing: ["Time Cook", "1"], buttons: 4)
        let fullFrame = Attempt(reference: reference, guidable: false, missing: [], buttons: 30)
        let ready = Attempt(reference: reference, guidable: true, missing: [], buttons: 3)
        let threw = Attempt(problem: .noPanel)
        #expect(beats(outline, fullFrame))
        #expect(beats(ready, outline))
        #expect(beats(fullFrame, threw))
        #expect(beats(Attempt(reference: reference, guidable: true, missing: ["Start"], buttons: 1), outline))
        #expect(beats(Attempt(reference: reference, guidable: true, missing: [], buttons: 9), ready))
        #expect(ready.isEnough && !outline.isEnough && !fullFrame.isEnough && !threw.isEnough)
        var loading = outline
        loading.warmingUp = true
        #expect(loading.isEnough, "No photo gets digit keys until the text model loads")
        var loadingFullFrame = fullFrame
        loadingFullFrame.warmingUp = true
        #expect(!loadingFullFrame.isEnough, "The text model doesn't find the outline")
    }

    @Test("A button belonging to an older panel cannot start guidance")
    func staleSelection() async throws {
        let model = makeModel(pipeline())
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        let original = try #require(model.map?.buttons.first)
        let stale = SurfaceMap.Button(label: original.label, bounds: original.bounds, confidence: original.confidence)
        model.choose(stale)
        #expect(!model.busy && !model.guiding)
        #expect(!model.pipeline.guidanceArrived)
    }

}

/// Records what the model says out loud, and finishes each sentence at once.
private final class SpokenLines: PlanSpeaking {
    var lines: [String] = []
    func speak(_ text: String) async { lines.append(text) }
    func stop() {}
}

private struct EmptyLaunchFrames: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> { AsyncStream { $0.finish() } }
}

/// Says nothing and finishes at once.
private final class QuietSpeaker: PlanSpeaking {
    func speak(_ text: String) async {}
    func stop() {}
}

/// Records what's said. A sentence starting with `held` isn't finished until
/// it's cut off by `stop()`, like the real one.
private final class RecordingSpeaker: PlanSpeaking {
    var spoken: [String] = []
    var held: String?
    private var holding: CheckedContinuation<Void, Never>?
    var isHolding: Bool { holding != nil }

    func speak(_ text: String) async {
        spoken.append(text)
        if let held, text.hasPrefix(held) { await withCheckedContinuation { holding = $0 } }
    }

    func stop() {
        holding?.resume()
        holding = nil
    }
}

/// Labels laid out on a grid, as a scan would give them.
private func keys(_ labels: [String]) -> SurfaceMap {
    SurfaceMap(buttons: labels.enumerated().map { i, label in
        SurfaceMap.Button(label: label, bounds: PanelRect(x: Double(i % 4) * 0.25, y: Double(i / 4) * 0.2,
                                                          width: 0.2, height: 0.15), confidence: 1)
    }, confidence: 1)
}

private let everyKey = keys(["Time Cook", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "Start/Pause", "Popcorn"])
private let missingTimeCook = keys(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "Start/Pause", "Express Cook"])
private let missingStart = keys(["Time Cook", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "Popcorn"])

/// Answers each scan with the next answer, then the last one over and over, and
/// keeps which photos it was shown.
private final class ScanSequence: ContourCore.SurfaceUnderstanding, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<SurfaceMap, SurfaceUnderstandingError>]
    private var shown: [UUID] = []
    private let latency: Duration

    init(_ answers: [Result<SurfaceMap, SurfaceUnderstandingError>], latency: Duration = .zero) {
        self.answers = answers
        self.latency = latency
    }

    var photoIDs: [UUID] { lock.withLock { shown } }

    func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        let answer = lock.withLock {
            shown.append(photo.id)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        if latency > .zero { try await Task.sleep(for: latency) }
        return PanelDetection(referencePhotoID: photo.id, quad: .fullFrame, map: try answer.get())
    }
}

@MainActor
private final class ListeningGate {
    private var began = false
    private var waiter: CheckedContinuation<Void, Never>?
    func started() { began = true; waiter?.resume(); waiter = nil }
    func waitForStart() async {
        if began { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private struct LaunchArrivalFrames: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { continuation in
            for _ in 0..<14 {
                continuation.yield(TrackingFrame(timestamp: Date(),
                    fingertip: MockSurfaceMaps.microwaveStartButton.bounds.center,
                    panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                        column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
            }
            continuation.finish()
        }
    }
}

private struct FailingMenuSurface: ContourCore.SurfaceUnderstanding {
    func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        throw NSError(domain: "MenuScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "No panel detected"])
    }
}
