import ContourCore
import ContourFeedback
import Foundation
import Observation
import SurfaceUnderstanding
import UIKit

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
    /// Whether a tap on Next does anything: from the start of a key's guidance until
    /// the following key is announced, or on the last key until its guidance ends.
    /// `next` checks this and the button is off without it, so they always agree.
    private(set) var canMoveOn = false
    private var planReferenceID: UUID?
    /// Goes in front of the status, so the demo can't be fooled by a silent failure:
    /// "Plan from OpenAI" or "Plan from phone". `nil` with no OpenAI set up.
    private(set) var planNote: String?
    private let openAI: OpenAIPlans?
    private var speaking = false
    private let listen: @MainActor (SurfaceMap) async throws -> VoiceRequest.Heard
    private let listenForNext: @MainActor () async throws -> Bool
    private let speaker: any PlanSpeaking
    private let voiceOverRunning: @MainActor () -> Bool
    private let warmingUp: @MainActor () -> Bool
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
         openAI: OpenAIPlans? = nil,
         voiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning },
         warmingUp: @escaping @MainActor () -> Bool = { LabelReader.isWarmingUp }) {
        self.camera = camera
        self.pipeline = pipeline
        self.listen = listen
        self.listenForNext = listenForNext
        self.speaker = speaker
        self.openAI = openAI
        self.voiceOverRunning = voiceOverRunning
        self.warmingUp = warmingUp
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
    /// Current reference/readiness owns selection availability, including manual
    /// setup after a failed scan. A past scan failure cannot hide a new target.
    var hasSelectionContent: Bool { pipeline.canGuide && !(map?.buttons.isEmpty ?? true) }
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
                    status = map.map { Self.readyStatus(for: $0) } ?? "Aim at the whole control panel, then scan."
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

    /// What to say once a panel is ready, and whether every cook time can be guided
    /// on it: Time Cook, the digits and Start, each one clear key, the same check a
    /// plan makes. Ovens and some panels really have no number keys, so the advice
    /// has to hold for those too. While the text model is still loading, a scan
    /// gets no digit keys wherever the phone is, so then it says to wait.
    nonisolated static func readyStatus(for map: SurfaceMap, warmingUp: Bool = false) -> String {
        let missing = CookTimePlan.missingKeys(in: map)
        guard !missing.isEmpty else { return "Panel ready. Cook times ready. Say a button name or choose one below." }
        let ready = "Panel ready. Say a button name or choose one below. "
        if warmingUp { return ready + "Cook times are still getting ready. Scan again in a moment." }
        return ready + "Cook times not ready, missing \(spoken(missing)). "
            + "If this panel has them, hold the phone about a foot away and scan again."
    }

    /// `keys` as a list to say, with "the number keys" for all of the digits.
    nonisolated private static func spoken(_ keys: [String]) -> String {
        let digits = CookTimePlan.cookTimeKeys.filter { $0.allSatisfy(\.isNumber) }
        var names = keys
        if let first = names.firstIndex(of: digits[0]), digits.allSatisfy(keys.contains) {
            names.removeAll(where: digits.contains)
            names.insert("the number keys", at: first)
        }
        return names.formatted(.list(type: .and))
    }

    func waitForWork() async { await work?.value }

    func referenceChanged() {
        let current = pipeline.panelReference?.photo.id
        guard current != knownReferenceID else { return }
        knownReferenceID = current
        guard !scanning else { return }
        stopWork()
        error = nil
        status = map.map { Self.readyStatus(for: $0) } ?? "Aim at the whole control panel, then scan."
    }

    /// Await this barrier before presenting diagnostics or starting replacement work.
    ///
    /// `endingGuidance: false` is for work that guides again straight away, like the
    /// next key of a plan. Cancelling the work still ends its guidance, but tracking
    /// keeps the panel instead of registering it again from the scan photo.
    @discardableResult
    func stopWork(endingGuidance: Bool = true) -> Task<Void, Never> {
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
        canMoveOn = false
        speaking = false
        let cleanup = Task {
            await previous?.value
            if endingGuidance { await pipeline.stopGuidance() }
        }
        work = cleanup
        return cleanup
    }

    func stop() {
        stopWork()
        status = "Stopped. Say a button name, choose a button, or scan again."
    }

    /// A scan takes up to this many photos, and no more once the next one would
    /// likely end after `scanBudget`.
    static let scanPhotos = 3
    static let scanBudget: Duration = .seconds(6)

    func scan() {
        guard ready else { return }
        replaceWork {
            self.scanning = true
            defer { self.scanning = false }
            self.status = "Scanning panel. Hold the phone steady."
            // Said out loud while the photos are taken, not before them.
            async let cue: Void = self.sayUnlessVoiceOver("Scanning panel. Hold the phone steady.")
            let line: String
            do {
                line = try await self.scanForBest()
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                self.error = error.localizedDescription
                line = "Unable to complete the request. Retry or choose a button below."
            }
            await cue
            try Task.checkCancellation()
            await self.finish(line)
        }
    }

    /// One photo's scan, ranked against the others from the same tap.
    struct ScanAttempt {
        var reference: PanelReference?
        /// Why the scan threw, when it did.
        var problem: ScanProblem?
        var guidable = false
        var missing: [String] = []
        var buttons = 0
        var warmingUp = false

        /// A scan that came back, then one that can guide, then the cook-time
        /// keys, then more buttons.
        var rank: (Int, Int, Int, Int) { (reference == nil ? 0 : 1, guidable ? 1 : 0, -missing.count, buttons) }

        /// Another photo can't do better: it guides, and has every cook-time key
        /// or can't have them until the text model has loaded.
        var isEnough: Bool { guidable && (missing.isEmpty || warmingUp) }
    }

    /// Scans new photos until one can guide and has every cook-time key, keeps the
    /// best as the panel, and returns what to say about it.
    ///
    /// Every photo is a new camera frame, but frames a second apart from the same
    /// spot look much alike. Trying again gets past the detector missing something
    /// on one frame, not a bad angle or distance, so a bad result still ends on
    /// what to change.
    private func scanForBest() async throws -> String {
        let started = ContinuousClock.now
        var best: ScanAttempt?
        for _ in 0..<Self.scanPhotos {
            let photoStarted = ContinuousClock.now
            let attempt: ScanAttempt
            do {
                attempt = try await scanOnce()
            } catch {
                // The camera failing on a later photo leaves the ones before it.
                guard best != nil, !(error is CancellationError) else { throw error }
                try Task.checkCancellation()
                break
            }
            if best.map({ attempt.rank >= $0.rank }) ?? true { best = attempt }
            if best?.isEnough == true
                || started.duration(to: .now) + photoStarted.duration(to: .now) > Self.scanBudget { break }
        }
        guard let best else { throw CancellationError() }
        if let reference = best.reference, pipeline.panelReference?.photo.id != reference.photo.id {
            await pipeline.replaceReference(with: reference)
            try Task.checkCancellation()
        }
        knownReferenceID = pipeline.panelReference?.photo.id

        guard let reference = best.reference else { return (best.problem ?? .scanFailed).spoken }
        guard !reference.detection.map.buttons.isEmpty else { return ScanProblem.noButtons.spoken }
        guard pipeline.canGuide else {
            return ScanProblem.after(reference.detection, photo: reference.photo, target: nil)?.spoken
                ?? "Panel outline unclear. Show all four corners and scan again."
        }
        warmUpOpenAI()
        return Self.readyStatus(for: reference.detection.map, warmingUp: best.warmingUp)
    }

    /// Scans one new photo. A scan that throws is a result too: the next photo may work.
    private func scanOnce() async throws -> ScanAttempt {
        let photo: PanelPhoto
        if usesCamera {
            // Always a frame from after this call, never one an earlier scan used.
            photo = try await camera.capturePanelPhoto()
        } else {
            photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 4032, height: 3024), timestamp: Date())
        }
        try Task.checkCancellation()
        // A load still going when the scan starts can leave its keypad read with nothing.
        let loading = warmingUp()
        do {
            let map = try await pipeline.detectPanel(in: photo)
            try Task.checkCancellation()
            return ScanAttempt(reference: pipeline.panelReference, guidable: !map.buttons.isEmpty && pipeline.canGuide,
                               missing: CookTimePlan.missingKeys(in: map), buttons: map.buttons.count,
                               warmingUp: loading)
        } catch {
            guard let problem = ScanProblem.after(error) else { throw CancellationError() }
            try Task.checkCancellation()
            return ScanAttempt(problem: problem)
        }
    }

    /// The last thing a piece of work says. The buttons work while it's said, and
    /// whatever the user does next cuts it off. VoiceOver reads the status line out
    /// itself, so this only speaks when VoiceOver is off: either way it's heard once.
    private func finish(_ line: String) async {
        busy = false
        scanning = false
        if voiceOverRunning() {
            status = line
        } else {
            await announce(line)
        }
    }

    /// Says `text` when VoiceOver is off, where nothing else would. It doesn't
    /// change the status.
    private func sayUnlessVoiceOver(_ text: String) async {
        guard !voiceOverRunning() else { return }
        await speaker.speak(text)
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
            let heard: VoiceRequest.Heard
            do {
                heard = try await self.listen(map)
            } catch is CancellationError {
                return
            } catch {
                // Said out loud, VoiceOver or not. The camera, the panel and the
                // buttons all still work.
                guard !Task.isCancelled else { return }
                self.listening = false
                // Like a scan's last line, a tap cuts it off.
                self.busy = false
                await self.announce("Voice isn't available. Choose a button below.")
                if !Task.isCancelled { self.error = error.localizedDescription }
                return
            }
            self.listening = false
            try Task.checkCancellation()
            guard self.pipeline.panelReference?.photo.id == referenceID else { return }
            guard !heard.text.isEmpty else {
                await self.finish("Didn't hear anything. Try speaking again or choose a button below.")
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
            // Any key the phone finds wins, even its guess at the next safest one: the
            // matcher's rules, like pause never becoming Cancel, don't hold on the server.
            if let openAI = self.openAI, heard.button == nil, !ButtonLookup.mentionsStopping(heard.text) {
                await self.ask(openAI, heard.text, map: map, referenceID: referenceID)
                return
            }
            guard let button = heard.button else {
                await self.finish("No button matching “\(heard.text)”. Try again or choose a button below.")
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
        await walk(plan, from: 0, referenceID: referenceID)
    }

    /// Everything the phone can't do alone, like "heat up my coffee". The model can
    /// be silently wrong, so its whole plan is said out loud before the first key.
    private func ask(_ openAI: OpenAIPlans, _ request: String, map: SurfaceMap, referenceID: UUID?) async {
        guard !CookTime.mentionsATime(request) else {
            notePhonePlan()
            await announce("I only know a minute and a half, 2 minutes or 30 seconds, so I won't guess that.")
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
            // Nothing to guide, so a sentence like "Press 1, 0, 0" would leave a finger
            // looking on its own. Only a reason that names no key is said.
            await announce(OpenAIPlans.soundsLikeKeys(plan.say, in: map) ? "OpenAI didn't find a plan for that." : plan.say)
            return
        }
        guard plan.steps.count <= OpenAIPlans.maxSteps else {
            await announce("OpenAI's plan has \(plan.steps.count) steps. That's too many to trust, so I won't run it.")
            return
        }
        switch CookTimePlan.make(serverSteps: plan.steps, in: map) {
        case .missing(let sentence):
            await announce(sentence)
        case .plan(let plan):
            await start(plan, referenceID: referenceID)
        }
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

    /// Moves on from the current key once its guidance has started, and through
    /// everything said about it after. Nothing detects a press, and arrival may
    /// never trigger, so this works then. Before that, a tap would skip a key
    /// nobody has heard about yet.
    func next() {
        guard let plan, canMoveOn else { return }
        let referenceID = planReferenceID
        let note = planNote
        let following = planIndex + 1
        guard following < plan.steps.count else {
            replaceWork { await self.announce("That was the last key.") }
            planNote = note
            return
        }
        replaceWork(endingGuidance: false) { await self.walk(plan, from: following, referenceID: referenceID) }
        // Replacing the work ended the plan. This is the same plan, one key on, and
        // `canMoveOn` stays off until that key is guided, so a second tap does nothing.
        self.plan = plan
        planIndex = following
        planNote = note
    }

    /// One key at a time. Stop, a rescan and `next` all cancel this work, so a
    /// cancelled step just returns.
    private func walk(_ plan: CookTimePlan, from first: Int, referenceID: UUID?) async {
        for index in first..<plan.steps.count {
            // Until this key is guided, a tap would skip it.
            canMoveOn = false
            guard pipeline.panelReference?.photo.id == referenceID else {
                self.plan = nil
                return
            }
            planIndex = index
            let step = plan.steps[index]
            await announce(plan.progress(at: index))
            if !Task.isCancelled { canMoveOn = true }
            await guide(step.button, referenceID: referenceID)
            guard !Task.isCancelled else { return }
            guard pipeline.panelReference?.photo.id == referenceID else {
                self.plan = nil
                return
            }
            let reached = pipeline.guidanceArrived
            let lead = reached ? "Press \(step.name)" : "Guidance ended before \(step.name)"
            // After the last key there's nowhere to move on to, and a tap mustn't
            // cut off the instruction to press it.
            if index == plan.steps.count - 1 { canMoveOn = false }
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
        var toldVoiceUnavailable = false
        while !Task.isCancelled {
            do {
                if try await listenForNext() { return !Task.isCancelled }
            } catch is CancellationError {
                return false
            } catch {
                let shown = "Can't listen: \(error.localizedDescription) Use the button to move on."
                // Once, out loud: the screen alone is silent without VoiceOver. Neither
                // says Next, because VoiceOver reads that button as Continue.
                if !toldVoiceUnavailable {
                    toldVoiceUnavailable = true
                    await announce("Voice isn't available. Use the button to move on.", showing: shown)
                }
                status = shown
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

    private func replaceWork(endingGuidance: Bool = true, _ operation: @escaping @MainActor () async throws -> Void) {
        let cleanup = stopWork(endingGuidance: endingGuidance)
        let id = UUID()
        requestID = id
        busy = true
        error = nil
        work = Task {
            await cleanup.value
            guard requestID == id, !Task.isCancelled, active else { return }
            defer {
                if requestID == id { busy = false; listening = false; guiding = false; canMoveOn = false }
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
