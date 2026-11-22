//
//  PlanWalkTests.swift
//  ContourTests
//
//  Throwaway multi-step demo: walking a plan through CameraLaunchModel with a fake
//  microphone, a fake voice and scripted fingers. Nothing here proves the real
//  microphone, speech or tracking.
//

import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import Observation
import Testing
import Tracking
@testable import ContourApp

/// A panel with every key a plan needs. Fresh ids on every call, like a real scan.
private func panel(timeCook: Bool = true, digits: String = "1234567890") -> SurfaceMap {
    var labels = digits.map(String.init) + ["Start/Pause", "Add 30 Sec"]
    if timeCook { labels.append("Time Cook") }
    return SurfaceMap(buttons: labels.enumerated().map { i, label in
        SurfaceMap.Button(label: label, bounds: PanelRect(x: Double(i % 4) * 0.25, y: Double(i / 4) * 0.25,
                                                          width: 0.2, height: 0.2), confidence: 1)
    }, confidence: 1)
}

/// Each `frames()` puts the finger on the key `target` names, long enough to hold.
private final class FingerOnTheKey: TrackingSource, @unchecked Sendable {
    private let lock = NSLock()
    private var streams = 0
    private let target: @MainActor () -> PanelPoint?
    init(target: @escaping @MainActor () -> PanelPoint?) { self.target = target }

    var streamCount: Int { lock.withLock { streams } }

    func frames() -> AsyncStream<TrackingFrame> {
        lock.withLock { streams += 1 }
        let target = target
        return AsyncStream { continuation in
            Task { @MainActor in
                for _ in 0..<14 {
                    continuation.yield(TrackingFrame(timestamp: Date(), fingertip: target(),
                        panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                            column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .good))
                }
                continuation.finish()
            }
        }
    }
}

/// Never arrives and never ends, like a phone that can't see the finger.
private struct NoFingertipEver: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> {
        AsyncStream { continuation in
            continuation.yield(TrackingFrame(timestamp: Date(), fingertip: nil,
                panel: PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0),
                    column2: SIMD4(0,0,1,0), column3: SIMD4(0,0,0,1), confidence: 1), trackingQuality: .degraded))
        }
    }
}

/// No fingertip ever, like `NoFingertipEver`, and counts each time tracking is
/// told to stop, which makes the real tracker register the panel again.
private actor StopCountingSession: GuidanceTrackingSession {
    private(set) var stops = 0
    func use(_ reference: PanelReference) {}
    func stop() { stops += 1 }
    func registrationError() -> PanelTrackingError? { nil }
    func hybridStatus() -> HybridTrackingDiagnostics? { nil }
    nonisolated func frames() -> AsyncStream<TrackingFrame> { NoFingertipEver().frames() }
}

/// Records what's said, and when it finished relative to the microphone.
private final class FakeSpeaker: PlanSpeaking {
    var log: [String] = []
    var stops = 0
    /// Sentences starting with this take long enough to tap Next during.
    var slow: String?
    /// A sentence starting with this isn't finished until `finish()`, or until
    /// it's cut off by `stop()` like the real one.
    var held: String?
    private var holding: CheckedContinuation<Void, Never>?
    var isHolding: Bool { holding != nil }
    var spoken: [String] { log.filter { !$0.hasPrefix("[") } }

    func speak(_ text: String) async {
        log.append(text)
        if let held, text.hasPrefix(held) {
            await withCheckedContinuation { holding = $0 }
        } else {
            // A real sentence takes a while. The model must wait for all of it.
            try? await Task.sleep(for: .milliseconds(slow.map { text.hasPrefix($0) } == true ? 300 : 5))
        }
        log.append("[finished]")
    }

    func finish() {
        holding?.resume()
        holding = nil
    }

    func stop() {
        stops += 1
        finish()
    }
}

@MainActor
@Suite("Walking a plan")
struct PlanWalkTests {
    private func pipeline(map: SurfaceMap, tracking: any TrackingSource) -> ContourPipeline {
        let epoch = ContinuousClock.now
        var tick = 0
        return ContourPipeline(surfaceUnderstanding: MockSurfaceUnderstanding(map: map), tracking: tracking,
            feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [], guidanceNow: {
                defer { tick += 1 }
                return epoch.advanced(by: .milliseconds(tick * 100))
            })
    }

    /// A model with a scanned panel. `say` is what the user asks for, and
    /// `next` answers each time the model listens for "next".
    private func scanned(say: String = "cook for a minute and a half", map: SurfaceMap = panel(),
                         tracking: (any TrackingSource)? = nil, speaker: FakeSpeaker,
                         next: @escaping @MainActor () async throws -> Bool = { true })
        async -> (model: CameraLaunchModel, finger: FingerOnTheKey) {
        // The finger follows the plan: whichever key the model is on right now.
        var read: (() -> PanelPoint?)?
        let finger = FingerOnTheKey { read?() }
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline(map: map, tracking: tracking ?? finger),
            listen: { map in VoiceRequest.Heard(text: say, button: ButtonLookup.button(for: say, in: map)) },
            listenForNext: next, speaker: speaker)
        read = { [weak model] in
            guard let model, let plan = model.plan else { return nil }
            return plan.steps[model.planIndex].button.bounds.center
        }
        await model.setActive(true).value
        model.scan()
        await model.waitForWork()
        // What the scan said isn't part of the plan.
        speaker.log.removeAll()
        return (model, finger)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private static let hangs: @MainActor () async throws -> Bool = {
        try await Task.sleep(for: .seconds(60))
        return false
    }

    @Test("Time Cook, 1, 3, 0, Start, one key at a time, saying each one")
    func walksEveryKey() async {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(speaker: speaker)
        model.sayAButton()
        await model.waitForWork()
        #expect(speaker.spoken == [
            "Cook for a minute and a half: Time Cook, 1, 3, 0, Start.",
            "Step 1 of 5: Time Cook", "Press Time Cook. Say next to move on.",
            "Step 2 of 5: 1", "Press 1. Say next to move on.",
            "Step 3 of 5: 3", "Press 3. Say next to move on.",
            "Step 4 of 5: 0", "Press 0. Say next to move on.",
            "Step 5 of 5: Start", "Press Start. That's the last key.",
        ])
        #expect(finger.streamCount == 5)
        #expect(model.plan == nil)
        #expect(!model.busy && !model.listening && !model.guiding)
        #expect(model.status == "Press Start. That's the last key.")
    }

    @Test("The same button twice in a row is guided twice")
    func repeatedDigit() async {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(say: "2 minutes", speaker: speaker)
        model.sayAButton()
        await model.waitForWork()
        #expect(finger.streamCount == 5)
        #expect(speaker.spoken.filter { $0 == "Press 0. Say next to move on." }.count == 2)
        #expect(speaker.spoken.contains("Step 3 of 5: 0") && speaker.spoken.contains("Step 4 of 5: 0"))
        #expect(model.status == "Press Start. That's the last key.")
    }

    @Test("The microphone opens only after the app has finished talking")
    func speechFinishesBeforeTheMicrophone() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: { speaker.log.append("[mic]"); return true })
        model.sayAButton()
        await model.waitForWork()
        let mic = speaker.log.indices.filter { speaker.log[$0] == "[mic]" }
        #expect(mic.count == 4)
        for index in mic {
            #expect(speaker.log[index - 1] == "[finished]")
            #expect(speaker.log[index - 2].hasSuffix("Say next to move on."))
        }
    }

    @Test("Not hearing next means waiting, not moving on")
    func waitsForNext() async {
        let speaker = FakeSpeaker()
        var answers = [false, false, true]
        let (model, _) = await scanned(say: "30 seconds", speaker: speaker, next: {
            answers.isEmpty ? try await Self.hangs() : answers.removeFirst()
        })
        model.sayAButton()
        await until { model.planIndex == 1 && model.listening }
        #expect(answers.isEmpty)
        #expect(model.planProgress == "Step 2 of 4: 3")
        model.stop()
        await model.waitForWork()
    }

    @Test("The Next button works during guidance, when arrival never triggers")
    func nextDuringGuidance() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(tracking: NoFingertipEver(), speaker: speaker)
        model.sayAButton()
        await until { model.guiding && model.planIndex == 0 }
        model.next()
        #expect(model.planProgress == "Step 2 of 5: 1")
        await until { model.guiding && model.planIndex == 1 }
        #expect(speaker.spoken.contains("Step 2 of 5: 1"))
        #expect(model.displayStatus.hasPrefix("Step 2 of 5: 1. "))
        #expect(model.busy)
        model.stop()
        await model.waitForWork()
    }

    @Test("The Next button keeps tracking the panel, and Stop ends it")
    func nextKeepsTracking() async {
        let speaker = FakeSpeaker()
        let session = StopCountingSession()
        let (model, _) = await scanned(tracking: session, speaker: speaker)
        model.sayAButton()
        await until { model.guiding && model.planIndex == 0 }
        let stops = await session.stops
        model.next()
        await until { model.guiding && model.planIndex == 1 }
        #expect(await session.stops == stops)
        model.stop()
        await model.waitForWork()
        #expect(await session.stops > stops)
    }

    @Test("The Next button works while listening for next")
    func nextWhileListening() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening && model.planIndex == 0 }
        model.next()
        await until { model.listening && model.planIndex == 1 }
        #expect(speaker.spoken.contains("Press 1. Say next to move on."))
        model.stop()
        await model.waitForWork()
    }

    @Test("Two quick taps on Next move on one key, and that key is said")
    func twoQuickNexts() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening && model.planIndex == 0 }
        model.next(); model.next()
        await until { model.listening }
        #expect(model.planProgress == "Step 2 of 5: 1")
        #expect(speaker.spoken.contains("Step 2 of 5: 1"))
        model.stop()
        await model.waitForWork()
    }

    @Test("Next while the plan is read back skips nothing")
    func nextDuringReadBack() async {
        let speaker = FakeSpeaker()
        speaker.slow = "Cook for"
        let (model, _) = await scanned(tracking: NoFingertipEver(), speaker: speaker)
        model.sayAButton()
        await until { model.status.hasPrefix("Cook for") }
        #expect(!model.canMoveOn, "The Next button is off")
        model.next()
        await until { model.guiding }
        #expect(model.planProgress == "Step 1 of 5: Time Cook")
        #expect(speaker.spoken.contains(model.planProgress ?? ""))
        model.stop()
        await model.waitForWork()
    }

    @Test("The Next button on the last key ends the plan")
    func nextOnTheLastKey() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(say: "30 seconds", tracking: NoFingertipEver(), speaker: speaker)
        model.sayAButton()
        await until { model.guiding }
        // A tap only counts once that key's guidance has started.
        for step in 1...3 {
            model.next()
            await until { model.guiding && model.planIndex == step }
        }
        #expect(model.planProgress == "Step 4 of 4: Start")
        #expect(model.canMoveOn, "The Next button is on while the last key is guided")
        model.next()
        #expect(model.plan == nil)
        await model.waitForWork()
        #expect(model.status == "That was the last key.")
        #expect(!model.busy && !model.guiding)
    }

    @Test("Next as soon as a key is reached, before anything is said, guides the following key")
    func nextOnceReached() async {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(speaker: speaker, next: Self.hangs)
        nextWhenGuidanceEnds(model)
        model.sayAButton()
        await until { model.listening && model.planIndex == 1 }
        #expect(!speaker.spoken.contains("Press Time Cook. Say next to move on."))
        #expect(speaker.spoken.contains("Step 2 of 5: 1"))
        #expect(speaker.spoken.contains("Press 1. Say next to move on."))
        #expect(finger.streamCount == 2)
        model.stop()
        await model.waitForWork()
    }

    @Test("Next while the key is being named cuts it off and guides the following key")
    func nextWhileNamingTheKey() async {
        let speaker = FakeSpeaker()
        speaker.held = "Press Time Cook"
        let (model, finger) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { speaker.isHolding }
        #expect(model.status == "Press Time Cook. Listening to move on.")
        #expect(model.canMoveOn, "The Next button is on")
        let stops = speaker.stops
        model.next()
        #expect(!model.canMoveOn, "A second tap waits for the following key")
        #expect(speaker.stops > stops)
        await until { model.listening && model.planIndex == 1 }
        #expect(speaker.spoken.contains("Step 2 of 5: 1"))
        #expect(speaker.spoken.contains("Press 1. Say next to move on."))
        #expect(finger.streamCount == 2)
        #expect(model.canMoveOn)
        model.stop()
        await model.waitForWork()
    }

    @Test("While the following key is announced, Next is off and a tap skips nothing")
    func nextWhileAnnouncingTheStep() async {
        let speaker = FakeSpeaker()
        speaker.held = "Step 2 of 5"
        // "next" is heard once, after the first key.
        var answers = [true]
        let (model, finger) = await scanned(speaker: speaker, next: {
            answers.isEmpty ? try await Self.hangs() : answers.removeFirst()
        })
        model.sayAButton()
        await until { speaker.isHolding }
        #expect(model.status == "Step 2 of 5: 1")
        #expect(!model.canMoveOn, "The Next button is off")
        model.next()
        #expect(model.plan != nil && model.planIndex == 1)
        speaker.finish()
        await until { model.listening && model.planIndex == 1 }
        #expect(model.canMoveOn)
        #expect(speaker.spoken.contains("Press 1. Say next to move on."))
        #expect(!speaker.spoken.contains("Step 3 of 5: 3"))
        #expect(finger.streamCount == 2)
        model.stop()
        await model.waitForWork()
    }

    @Test("Once the last key is reached, Next is off and doesn't cut off what to do")
    func nextAfterTheLastKey() async {
        let speaker = FakeSpeaker()
        speaker.held = "Press Start"
        let (model, _) = await scanned(say: "30 seconds", speaker: speaker)
        model.sayAButton()
        await until { speaker.isHolding }
        #expect(model.status == "Press Start. That's the last key.")
        #expect(!model.canMoveOn, "The Next button is off")
        let stops = speaker.stops
        model.next()
        #expect(speaker.stops == stops && model.plan != nil)
        speaker.finish()
        await model.waitForWork()
        #expect(model.status == "Press Start. That's the last key.")
        #expect(!speaker.spoken.contains("That was the last key."))
        #expect(model.plan == nil && !model.canMoveOn)
    }

    @Test("Stop and choosing a button turn the Next button off", arguments: [false, true])
    func stopTurnsNextOff(choosing: Bool) async throws {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        #expect(model.canMoveOn)
        if choosing {
            model.choose(try #require(model.map?.button(labelled: "Add 30 Sec")))
        } else {
            model.stop()
        }
        #expect(!model.canMoveOn)
        await model.waitForWork()
        #expect(!model.canMoveOn && model.plan == nil)
    }

    @Test("Stop ends the whole plan", arguments: [true, false])
    func stopEndsThePlan(whileListening: Bool) async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(tracking: whileListening ? nil : NoFingertipEver(), speaker: speaker,
                                       next: Self.hangs)
        model.sayAButton()
        await until { whileListening ? model.listening : model.guiding }
        let said = speaker.spoken.count
        let stops = speaker.stops
        model.stop()
        #expect(model.plan == nil && model.planProgress == nil)
        #expect(speaker.stops > stops)
        await model.waitForWork()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(speaker.spoken.count == said)
        #expect(!model.busy && !model.listening && !model.guiding)
        #expect(model.status.hasPrefix("Stopped"))
        model.next()
        #expect(!model.busy)
    }

    @Test("A rescan ends the plan, and the old ids are never guided to")
    func rescanEndsThePlan() async throws {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        let streams = finger.streamCount
        model.scan()
        #expect(model.plan == nil)
        await model.waitForWork()
        #expect(!model.busy && model.plan == nil)
        #expect(finger.streamCount == streams)
        #expect(model.status.contains("Panel ready"))
    }

    @Test("A panel replaced behind the plan's back ends it")
    func replacedPanelEndsThePlan() async throws {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        _ = try await model.pipeline.detectPanel(in: PanelPhoto(data: Data(),
            pixelSize: PixelSize(width: 100, height: 100), timestamp: Date()))
        let streams = finger.streamCount
        // The screen hasn't told the model yet. Moving on must not use the old map.
        model.next()
        await until { model.plan == nil }
        await model.waitForWork()
        #expect(finger.streamCount == streams)
        #expect(!model.busy)

        model.referenceChanged()
        #expect(model.plan == nil)
    }

    @Test("Going to the background ends the plan")
    func backgroundEndsThePlan() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        await model.setActive(false).value
        #expect(model.plan == nil && !model.busy && !model.listening)
    }

    @Test("Choosing a button on screen ends the plan")
    func chooseEndsThePlan() async throws {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        model.choose(try #require(model.map?.button(labelled: "Add 30 Sec")))
        #expect(model.plan == nil)
        await model.waitForWork()
        #expect(model.status == "Reached Add 30 Sec." || model.status.contains("Guidance ended"))
        #expect(!model.busy)
    }

    @Test("A missing digit guides nowhere and says which key")
    func missingDigit() async {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(map: panel(digits: "124567890"), speaker: speaker)
        model.sayAButton()
        await model.waitForWork()
        #expect(finger.streamCount == 0)
        #expect(model.plan == nil && !model.busy)
        #expect(model.status.contains("for 3 on this panel"))
        #expect(speaker.spoken == [model.status])
    }

    @Test("No Time Cook: no number is guided, since one pressed first can start cooking, and it says to scan again")
    func noTimeCook() async {
        let speaker = FakeSpeaker()
        let (model, finger) = await scanned(map: panel(timeCook: false), speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await model.waitForWork()
        #expect(finger.streamCount == 0)
        #expect(model.plan == nil && !model.busy)
        #expect(model.status == CookTimePlan.noClearKey(for: ["Time Cook"]))
        #expect(model.status.hasSuffix("Try scanning again."))
        #expect(speaker.spoken == [model.status])
    }

    @Test("The microphone failing doesn't end the plan, and Next still works")
    func listeningFails() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: {
            throw NSError(domain: "VoiceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone."])
        })
        model.sayAButton()
        await until { model.status.contains("No microphone.") }
        #expect(model.plan != nil && model.busy)
        model.next()
        await until { model.planIndex == 1 && model.status.contains("No microphone.") }
        model.stop()
        await model.waitForWork()
    }

    @Test("Guidance ending early doesn't claim the finger got there")
    func guidanceEnded() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(tracking: LaunchEmptyFrames(), speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        #expect(speaker.spoken.contains("Guidance ended before Time Cook. Say next to move on."))
        #expect(!speaker.spoken.contains { $0.hasPrefix("Press") })
        model.stop()
        await model.waitForWork()
    }

    @Test("The status never shows the word next while the microphone may be open")
    func statusAvoidsTheWord() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        model.sayAButton()
        await until { model.listening }
        #expect(model.status == "Press Time Cook. Listening to move on.")
        #expect(!NextWord.isIn(model.displayStatus))
        model.stop()
        await model.waitForWork()
    }

    @Test("VoiceOver stays out of it while the model does its own talking")
    func speaksOwnStatus() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(speaker: speaker, next: Self.hangs)
        #expect(!model.speaksOwnStatus)
        model.sayAButton()
        await until { model.listening }
        #expect(model.speaksOwnStatus)
        model.stop()
        #expect(!model.speaksOwnStatus)
        await model.waitForWork()
    }

    @Test("A request with no cook time still guides to one button", arguments: ["add 30 seconds", "start", "go"])
    func oneButton(request: String) async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(say: request, tracking: LaunchEmptyFrames(), speaker: speaker)
        model.sayAButton()
        await model.waitForWork()
        #expect(speaker.spoken.isEmpty)
        #expect(model.plan == nil)
        #expect(model.status.contains("Guidance ended"))
    }

    @Test("What's missing is plain: panel lost, or no fingertip")
    func gap() {
        #expect(ContourPipeline.gap(in: .lost(at: Date())) == "Panel lost.")
        let pose = PanelPose(column0: SIMD4(1,0,0,0), column1: SIMD4(0,1,0,0), column2: SIMD4(0,0,1,0),
                             column3: SIMD4(0,0,0,1), confidence: 1)
        #expect(ContourPipeline.gap(in: TrackingFrame(timestamp: Date(), fingertip: nil, panel: pose,
                                                      trackingQuality: .degraded)) == "No fingertip seen.")
        #expect(ContourPipeline.gap(in: TrackingFrame(timestamp: Date(), fingertip: PanelPoint(x: 0.5, y: 0.5),
                                                      panel: pose, trackingQuality: .good)) == nil)
    }

    @Test("The pipeline reports the gap while it's guiding")
    func pipelineReportsGap() async {
        let speaker = FakeSpeaker()
        let (model, _) = await scanned(tracking: NoFingertipEver(), speaker: speaker)
        model.sayAButton()
        await until { model.pipeline.guidanceGap == "No fingertip seen." }
        model.stop()
        await model.waitForWork()
    }
}

private struct LaunchEmptyFrames: TrackingSource {
    func frames() -> AsyncStream<TrackingFrame> { AsyncStream { $0.finish() } }
}

/// Taps Next the moment guidance to a key ends, before anything is said about it.
/// On a phone that moment lasts while "Target reached" finishes. With these fakes
/// it takes no time, so this catches the status as it changes away from "Guiding
/// to", which happens just after `guiding` goes false.
@MainActor
private func nextWhenGuidanceEnds(_ model: CameraLaunchModel) {
    withObservationTracking { _ = model.status } onChange: {
        MainActor.assumeIsolated {
            // Called just before the change, so the status still says "Guiding to".
            if !model.guiding && model.status.hasPrefix("Guiding to") {
                model.next()
            } else {
                nextWhenGuidanceEnds(model)
            }
        }
    }
}
