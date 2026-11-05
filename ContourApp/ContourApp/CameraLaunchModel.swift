import ContourCore
import ContourFeedback
import Foundation
import Observation
import SurfaceUnderstanding

/// Coordinates cancellation before the shared camera changes ownership or a new request starts.
@MainActor @Observable
final class CameraLaunchModel {
    let camera: CameraService
    let pipeline: ContourPipeline
    private(set) var status = "Aim at the whole control panel, then scan."
    private(set) var busy = false
    private(set) var ready = false
    private(set) var error: String?
    private(set) var listening = false
    private(set) var guiding = false
    private(set) var scanning = false
    /// The keys being walked through, one `guide` at a time. Button ids change on
    /// every scan, so anything that stops the current work ends the plan with it.
    private(set) var plan: CookTimePlan?
    private(set) var planIndex = 0
    private var planReferenceID: UUID?
    /// Goes in front of the status, so the demo can't be fooled by a silent failure:
    /// "Plan from OpenAI" or "Plan from phone". `nil` with no OpenAI set up.
    private(set) var planNote: String?
    private let openAI: OpenAIPlans?
    private var speaking = false
    private let listen: @MainActor (SurfaceMap) async throws -> VoiceRequest.Heard
    private let listenForNext: @MainActor () async throws -> Bool
    private let speaker: any PlanSpeaking
    private var knownReferenceID: UUID?
    private var active = false
    private var work: Task<Void, Never>?
    private var requestID = UUID()
    private var transition: Task<Void, Never>?
    private var lifecycleID = UUID()

    init(camera: CameraService, pipeline: ContourPipeline,
         listen: @escaping @MainActor (SurfaceMap) async throws -> VoiceRequest.Heard = { try await VoiceRequest().listen(for: $0) },
         listenForNext: @escaping @MainActor () async throws -> Bool = { try await VoiceRequest().listenForNext() },
         speaker: any PlanSpeaking = PlanSpeaker(),
         openAI: OpenAIPlans? = nil) {
        self.camera = camera
        self.pipeline = pipeline
        self.listen = listen
        self.listenForNext = listenForNext
        self.speaker = speaker
        self.openAI = openAI
        knownReferenceID = pipeline.panelReference?.photo.id
    }

    /// Share visual instructions with the same policy that drives speech/haptics.
    var displayStatus: String {
        var line = status
        if guiding, let feedback = pipeline.feedback as? LiveFeedbackEngine {
            line = [feedback.instructionText, pipeline.guidanceGap].compactMap { $0 }.joined(separator: " ")
        }
        if let planProgress, line != planProgress { line = "\(planProgress). \(line)" }
        if let planNote { line = "\(planNote). \(line)" }
        return line
    }

    var planProgress: String? { plan?.progress(at: planIndex) }

    /// This model is saying its status out loud, so VoiceOver shouldn't read it
    /// on top, and can't be reading it when the microphone opens.
    var speaksOwnStatus: Bool { speaking || plan != nil }

    var map: SurfaceMap? { pipeline.panelReference?.detection.map }
    var usesCamera: Bool {
        pipeline.liveComponents.contains(.surfaceUnderstanding) || pipeline.liveComponents.contains(.tracking)
    }

    @discardableResult
    func setActive(_ value: Bool) -> Task<Void, Never> {
        active = value
        ready = false
        let previous = transition
        let cleanup = stopWork()
        let id = UUID()
        lifecycleID = id
        let task = Task {
            await previous?.value
            await cleanup.value
            guard lifecycleID == id else { return }
            if !value {
                await camera.stop()
            } else if active {
                do {
                    if usesCamera { try await camera.start() }
                    guard lifecycleID == id, active else { return }
                    ready = true
                    error = nil
                    status = map == nil ? "Aim at the whole control panel, then scan."
                        : "Panel ready. Say a button name or choose one below."
                } catch {
                    guard lifecycleID == id, active else { return }
                    self.error = error.localizedDescription
                    status = "Camera unavailable. Enable camera access in Settings, then retry."
                }
            }
        }
        transition = task
        return task
    }

    func waitForWork() async { await work?.value }

    func referenceChanged() {
        let current = pipeline.panelReference?.photo.id
        guard current != knownReferenceID else { return }
        knownReferenceID = current
        guard !scanning else { return }
        stopWork()
        error = nil
        status = map == nil ? "Aim at the whole control panel, then scan."
            : "Panel ready. Say a button name or choose one below."
    }

    /// Await this barrier before presenting diagnostics or starting replacement work.
    @discardableResult
    func stopWork() -> Task<Void, Never> {
        requestID = UUID()
        let previous = work
        previous?.cancel()
        // Silence immediately, even while a camera/recognizer operation unwinds.
        (pipeline.feedback as? LiveFeedbackEngine)?.stop()
        speaker.stop()
        busy = false
        listening = false
        guiding = false
        scanning = false
        plan = nil
        planNote = nil
        speaking = false
        let cleanup = Task {
            await previous?.value
            await pipeline.stopGuidance()
        }
        work = cleanup
        return cleanup
    }

    func stop() {
        stopWork()
        status = "Stopped. Say a button name, choose a button, or scan again."
    }

    func scan() {
        guard ready else { return }
        replaceWork {
            self.scanning = true
            defer { self.scanning = false }
            self.status = "Scanning panel. Hold the phone steady."
            let photo: PanelPhoto
            if self.usesCamera {
                photo = try await self.camera.capturePanelPhoto()
            } else {
                photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 4032, height: 3024), timestamp: Date())
            }
            try Task.checkCancellation()
            let map = try await self.pipeline.detectPanel(in: photo)
            try Task.checkCancellation()
            self.knownReferenceID = self.pipeline.panelReference?.photo.id
            guard !map.buttons.isEmpty else {
                self.status = "No buttons found. Show the whole panel and scan again."
                return
            }
            guard self.pipeline.canGuide else {
                self.status = "Panel outline unclear. Show all four corners and scan again."
                return
            }
            self.status = "Panel ready. Say a button name or choose one below."
            self.warmUpOpenAI()
        }
    }

    /// Gets a token now so the first request doesn't spend its time limit on one.
    /// This only talks to App Check. Nothing goes to the plan server during a scan.
    private func warmUpOpenAI() {
        guard let openAI else { return }
        let referenceID = pipeline.panelReference?.photo.id
        Task {
            let note: String
            do {
                _ = try await openAI.token()
                note = "OpenAI ready"
            } catch is CancellationError {
                return
            } catch {
                note = "OpenAI not ready, \(error.localizedDescription)"
            }
            guard pipeline.panelReference?.photo.id == referenceID, planNote == nil else { return }
            planNote = note
        }
    }

    func sayAButton() {
        guard ready, let map, pipeline.canGuide else { return }
        let referenceID = pipeline.panelReference?.photo.id
        replaceWork {
            self.listening = true
            self.status = "Listening. Say the name of a button on the panel."
            let heard = try await self.listen(map)
            self.listening = false
            try Task.checkCancellation()
            guard self.pipeline.panelReference?.photo.id == referenceID else { return }
            guard !heard.text.isEmpty else {
                self.status = "Didn't hear anything. Try speaking again or choose a button below."
                return
            }
            switch CookTimePlan.make(for: heard.text, in: map) {
            case .missing(let sentence):
                self.notePhonePlan()
                await self.announce(sentence)
                return
            case .plan(let plan):
                self.notePhonePlan()
                await self.start(plan, referenceID: referenceID)
                return
            case nil:
                break
            }
            if let openAI = self.openAI, !ButtonLookup.isConfident(heard.text, in: map) {
                await self.ask(openAI, heard.text, map: map, referenceID: referenceID)
                return
            }
            guard let button = heard.button else {
                self.status = "No button matching “\(heard.text)”. Try again or choose a button below."
                return
            }
            self.notePhonePlan()
            await self.guide(button, referenceID: referenceID)
        }
    }

    private func notePhonePlan() {
        if openAI != nil { planNote = "Plan from phone" }
    }

    private func start(_ plan: CookTimePlan, referenceID: UUID?) async {
        self.plan = plan
        planIndex = 0
        planReferenceID = referenceID
        await announce(plan.say)
        if let warning = plan.warning { await announce(warning) }
        await walk(plan, from: 0, referenceID: referenceID)
    }

    /// Everything the phone can't do alone, like "heat up my coffee". The model can
    /// be silently wrong, so its whole plan is said out loud before the first key.
    private func ask(_ openAI: OpenAIPlans, _ request: String, map: SurfaceMap, referenceID: UUID?) async {
        guard !CookTime.mentionsATime(request) else {
            notePhonePlan()
            await announce("I only know a minute and a half, 2 minutes and 30 seconds, so I won't guess that.")
            return
        }
        async let answer = openAI.planner.plan(request, in: map)
        await announce("Asking OpenAI.")
        let plan = await answer
        guard !Task.isCancelled, pipeline.panelReference?.photo.id == referenceID else { return }

        if let fallback = plan.fallback {
            planNote = "Plan from phone, OpenAI \(fallback.why)"
            await announce("OpenAI \(fallback.why), so using the phone.")
            await announce(plan.say)
            if let button = plan.steps.first { await guide(button, referenceID: referenceID) }
            return
        }
        planNote = "Plan from OpenAI"
        guard !plan.steps.isEmpty else {
            await announce(plan.say)
            return
        }
        guard plan.steps.count <= OpenAIPlans.maxSteps else {
            await announce("OpenAI's plan has \(plan.steps.count) steps. That's too many to trust, so I won't run it.")
            return
        }
        await start(CookTimePlan(serverSteps: plan.steps, in: map), referenceID: referenceID)
    }

    func choose(_ button: SurfaceMap.Button) {
        guard ready, pipeline.canGuide, map?.buttons.contains(where: { $0.id == button.id }) == true else { return }
        let referenceID = pipeline.panelReference?.photo.id
        replaceWork { await self.guide(button, referenceID: referenceID) }
    }

    private func guide(_ button: SurfaceMap.Button, referenceID: UUID?) async {
        guard pipeline.panelReference?.photo.id == referenceID, !Task.isCancelled else { return }
        guiding = true
        status = "Guiding to \(button.label ?? "selected button"). Keep the panel in view and move your finger toward the target."
        await pipeline.guide(to: button)
        guard !Task.isCancelled, pipeline.panelReference?.photo.id == referenceID else { return }
        guiding = false
        status = pipeline.guidanceArrived ? "Reached \(button.label ?? "the selected button")."
            : "Guidance ended. Choose the button to retry, or scan again."
        error = pipeline.trackingError
    }

    /// Moves on from the current key once its guidance or listening has started.
    /// Nothing detects a press, and arrival may never trigger, so this works then.
    /// Before that, a tap would skip a key nobody has heard about yet.
    func next() {
        guard let plan, guiding || listening else { return }
        let referenceID = planReferenceID
        let note = planNote
        let following = planIndex + 1
        guard following < plan.steps.count else {
            replaceWork { await self.announce("That was the last key.") }
            planNote = note
            return
        }
        replaceWork { await self.walk(plan, from: following, referenceID: referenceID) }
        // Replacing the work ended the plan. This is the same plan, one key on.
        self.plan = plan
        planIndex = following
        planNote = note
    }

    /// One key at a time. Stop, a rescan and `next` all cancel this work, so a
    /// cancelled step just returns.
    private func walk(_ plan: CookTimePlan, from first: Int, referenceID: UUID?) async {
        for index in first..<plan.steps.count {
            guard pipeline.panelReference?.photo.id == referenceID else {
                self.plan = nil
                return
            }
            planIndex = index
            let step = plan.steps[index]
            await announce(plan.progress(at: index))
            await guide(step.button, referenceID: referenceID)
            guard !Task.isCancelled else { return }
            guard pipeline.panelReference?.photo.id == referenceID else {
                self.plan = nil
                return
            }
            let reached = pipeline.guidanceArrived
            let lead = reached ? "Press \(step.name)" : "Guidance ended before \(step.name)"
            await quietFeedback()
            guard index < plan.steps.count - 1 else {
                await announce("\(lead). That's the last key.")
                if !Task.isCancelled { self.plan = nil }
                return
            }
            // The screen leaves out the word: VoiceOver can read this text aloud
            // while the microphone is open. Out loud the word isn't last, so the
            // end of the sentence, or its echo, is less likely to count as a "next".
            await announce("\(lead). Say next to move on.", showing: "\(lead). Listening to move on.")
            guard await waitForNext() else { return }
        }
    }

    /// Lets "Target reached" finish, then goes silent so the microphone only
    /// hears the user. At most 3 s, in case the clip never reports finishing.
    private func quietFeedback() async {
        guard let live = pipeline.feedback as? LiveFeedbackEngine else { return }
        for _ in 0..<60 where live.voice.isSpeaking && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        live.stop()
    }

    /// Listens until "next" is heard. False if this work was cancelled instead.
    /// Failing to listen doesn't end the plan, because the Next button still works.
    private func waitForNext() async -> Bool {
        listening = true
        defer { listening = false }
        while !Task.isCancelled {
            do {
                if try await listenForNext() { return !Task.isCancelled }
            } catch is CancellationError {
                return false
            } catch {
                status = "Can't listen: \(error.localizedDescription) Use the button to move on."
            }
            // The microphone has to reopen, so don't spin if it ends straight away.
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Shows `text` and says it out loud, whether or not VoiceOver is on, and
    /// returns once it's finished.
    private func announce(_ text: String, showing shown: String? = nil) async {
        guard !Task.isCancelled else { return }
        speaking = true
        status = shown ?? text
        await speaker.speak(text)
        if !Task.isCancelled { speaking = false }
    }

    private func replaceWork(_ operation: @escaping @MainActor () async throws -> Void) {
        let cleanup = stopWork()
        let id = UUID()
        requestID = id
        busy = true
        error = nil
        work = Task {
            await cleanup.value
            guard requestID == id, !Task.isCancelled, active else { return }
            defer {
                if requestID == id { busy = false; listening = false; guiding = false }
            }
            do { try await operation() }
            catch is CancellationError { }
            catch {
                guard requestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                status = "Unable to complete the request. Retry or choose a button below."
            }
        }
    }
}
