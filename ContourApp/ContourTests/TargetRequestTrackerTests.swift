import ContourCore
import ContourFeedback
import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Multi-step target requests")
struct TargetRequestTrackerTests {
    @Test("Four steps keep separate results, even when the same key appears twice")
    func repeatedTargetSequence() async throws {
        let buttons = [button("1"), button("0"), button("Start")]
        let reference = try panel(buttons)
        let script = HoldScript(Array(repeating: onTargetFrames(), count: 4))
        let tracker = TargetRequestTracker(operation: { request in await script.run(request) })
        tracker.use(reference)

        let targets = [buttons[0], buttons[1], buttons[1], buttons[2]]
        let results = await runSequence(targets, tracker: tracker)
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0.status == .reached })
        #expect(results.map(\.target.id) == targets.map(\.id))
        #expect(Set(results.map(\.requestID)).count == 4)
        #expect(results.allSatisfy { $0.referenceID == reference.photo.id })
        #expect(Set(script.requests.map(\.id)).count == 4)
    }

    @Test("A B C works against one reference")
    func abc() async throws {
        let buttons = [button("A"), button("B"), button("C")]
        let ref = try panel(buttons)
        let script = HoldScript(Array(repeating: onTargetFrames(), count: 3))
        let tracker = TargetRequestTracker(operation: { request in await script.run(request) })
        tracker.use(ref)
        let results = await runSequence(buttons, tracker: tracker)
        #expect(results.map(\.status) == [.reached, .reached, .reached])
        #expect(script.requests.map(\.target.id) == buttons.map(\.id))
    }

    @Test("Loss breaks the hold; an ended request can be retried")
    func trackingLossAndRetry() async throws {
        let target = button("A")
        let script = HoldScript([
            Array(repeating: onTarget(), count: 11) + [lost()] + Array(repeating: onTarget(), count: 5),
            Array(repeating: onTarget(), count: 11) + [lost()] + onTargetFrames()
        ])
        let tracker = TargetRequestTracker(operation: { request in await script.run(request) })
        let ref = try panel([target])
        tracker.use(ref)
        let first = await tracker.guide(to: target)
        let retry = await tracker.guide(to: target)
        #expect(first.status == .endedWithoutArrival)
        #expect(retry.status == .reached)
        #expect(first.requestID != retry.requestID)
        #expect(script.requests.count == 2)
    }

    @Test("An invalid target cannot use the prepared panel")
    func rejectsForeignTargets() async throws {
        let target = button("A")
        let foreign = button("B")
        let script = HoldScript([onTargetFrames()])
        let tracker = TargetRequestTracker(operation: { request in await script.run(request) })
        let ref = try panel([target])
        tracker.use(ref)
        let result = await tracker.guide(to: foreign)
        #expect(result.status == .invalidTarget)
        #expect(result.referenceID == ref.photo.id)
        #expect(script.requests.isEmpty)

        // Even a copied ID is not enough if its geometry was changed.
        let altered = SurfaceMap.Button(id: target.id, label: target.label,
                                        bounds: foreign.bounds, confidence: 1)
        #expect((await tracker.guide(to: altered)).status == .invalidTarget)
        #expect(script.requests.isEmpty)
    }

    @Test("Stop invalidates a late arrival")
    func stop() async throws {
        let target = button("A")
        let suspended = SuspendedGuidance()
        let tracker = TargetRequestTracker(operation: { request in await suspended.run(request) })
        tracker.use(try panel([target]))
        let pending = Task { await tracker.guide(to: target) }
        await suspended.waitForRequests(1)
        tracker.stop()
        suspended.complete(0, with: .arrived)
        #expect((await pending.value).status == .cancelled)
    }

    @Test("A new request supersedes a delayed old arrival")
    func newerRequest() async throws {
        let a = button("A"), b = button("B")
        let suspended = SuspendedGuidance()
        let tracker = TargetRequestTracker(operation: { request in await suspended.run(request) })
        tracker.use(try panel([a, b]))
        let old = Task { await tracker.guide(to: a) }
        await suspended.waitForRequests(1)
        let new = Task { await tracker.guide(to: b) }
        await suspended.waitForRequests(2)
        suspended.complete(0, with: .arrived)
        suspended.complete(1, with: .endedWithoutArrival)
        #expect((await old.value).status == .cancelled)
        #expect((await new.value).status == .endedWithoutArrival)
    }

    @Test("Replacing a panel rejects old completion and old targets")
    func replaceReference() async throws {
        let a = button("A"), b = button("B")
        let first = try panel([a])
        let next = try panel([b])
        let suspended = SuspendedGuidance()
        let tracker = TargetRequestTracker(operation: { request in await suspended.run(request) })
        tracker.use(first)
        let old = Task { await tracker.guide(to: a) }
        await suspended.waitForRequests(1)
        tracker.use(next)
        suspended.complete(0, with: .arrived)
        #expect((await old.value).status == .cancelled)
        #expect((await tracker.guide(to: a)).status == .invalidTarget)
        #expect(tracker.reference?.photo.id == next.photo.id)
        #expect(suspended.requests.count == 1)
    }

    @Test("Cancelling the caller also rejects late arrival")
    func callerCancellation() async throws {
        let target = button("A")
        let suspended = SuspendedGuidance()
        let tracker = TargetRequestTracker(operation: { request in await suspended.run(request) })
        tracker.use(try panel([target]))
        let caller = Task { await tracker.guide(to: target) }
        await suspended.waitForRequests(1)
        caller.cancel()
        suspended.complete(0, with: .arrived)
        #expect((await caller.value).status == .cancelled)
    }

    private func runSequence(_ targets: [SurfaceMap.Button], tracker: TargetRequestTracker) async -> [TargetRequestResult] {
        var results: [TargetRequestResult] = []
        for target in targets {
            let result = await tracker.guide(to: target)
            results.append(result)
            if result.status != .reached { break }
        }
        return results
    }

    private func button(_ name: String) -> SurfaceMap.Button {
        SurfaceMap.Button(label: name,
                          bounds: PanelRect(x: name == "B" ? 0.5 : 0.1, y: 0.1, width: 0.2, height: 0.2),
                          confidence: 1)
    }

    private func panel(_ buttons: [SurfaceMap.Button]) throws -> PanelReference {
        let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 32, height: 32), timestamp: Date())
        let detection = PanelDetection(referencePhotoID: photo.id, quad: .fullFrame,
                                       map: SurfaceMap(buttons: buttons, confidence: 1))
        return try PanelReference(photo: photo, detection: detection)
    }

    private func onTarget() -> GuidanceState {
        GuidanceState(timestamp: Date(), vector: .onTarget)
    }

    private func lost() -> GuidanceState {
        .outcome(.lostTracking, at: Date())
    }

    private func onTargetFrames() -> [GuidanceState] {
        Array(repeating: onTarget(), count: 15)
    }
}

@MainActor
private final class HoldScript {
    private var scripts: [[GuidanceState]]
    private(set) var requests: [TargetGuidanceRequest] = []

    init(_ scripts: [[GuidanceState]]) { self.scripts = scripts }

    func run(_ request: TargetGuidanceRequest) async -> TargetGuidanceEvidence {
        requests.append(request)
        let frames = scripts.removeFirst()
        var hold = GuidanceArrivalHold() // every request starts its own hold
        let start = ContinuousClock.now
        for (index, frame) in frames.enumerated() {
            if Task.isCancelled { return .endedWithoutArrival }
            let now = start.advanced(by: .milliseconds(index * 100))
            if hold.update(frame, at: now).outcome == .arrived { return .arrived }
        }
        return .endedWithoutArrival
    }
}

@MainActor
private final class SuspendedGuidance {
    private(set) var requests: [TargetGuidanceRequest] = []
    private var continuations: [CheckedContinuation<TargetGuidanceEvidence, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ request: TargetGuidanceRequest) async -> TargetGuidanceEvidence {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            let ready = countWaiters.filter { requests.count >= $0.0 }
            countWaiters.removeAll { requests.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func complete(_ index: Int, with evidence: TargetGuidanceEvidence) {
        continuations[index].resume(returning: evidence)
    }
}
