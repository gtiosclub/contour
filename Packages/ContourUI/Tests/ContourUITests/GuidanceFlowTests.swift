//
//  GuidanceFlowTests.swift
//  ContourUI — Experience / App Flow
//
//  The state machine and its accessibility script. A blind user only knows the
//  app moved on because it said so, so every stage must say something, and
//  the four outcomes must not sound alike.
//

import ContourCore
import ContourMocks
import Testing
@testable import ContourUI

/// Collects what the flow would have said.
private actor Announcements {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}

private let map = MockSurfaceMaps.microwave
private let start = MockSurfaceMaps.microwaveStartButton
private let popcorn = MockSurfaceMaps.microwave.button(labelled: "Popcorn")!

/// One example of every stage, with every outcome.
private let everyStage: [GuidanceFlowStage] = [
    .idle, .acquiringPanel, .detecting, .selectingTarget(map), .guiding(start),
] + OutcomeSignal.allCases.map { .finished($0) }

/// The legal moves between the stages above, written out independently of the
/// implementation so the table is pinned twice.
private func expectedLegal(_ from: GuidanceFlowStage, _ to: GuidanceFlowStage) -> Bool {
    if from == to { return false }
    if to == .idle { return true }
    switch from {
    case .idle: return to == .acquiringPanel
    case .acquiringPanel: return to == .detecting
    case .detecting: return to == .selectingTarget(map) || to == .acquiringPanel || to == .finished(.lowConfidence)
    case .selectingTarget: return to == .guiding(start) || to == .acquiringPanel || to == .finished(.notFound)
    case .guiding: return to.kind == .finished || to == .selectingTarget(map) || to == .acquiringPanel
    case .finished: return to == .acquiringPanel || to == .guiding(start) || to == .selectingTarget(map)
    }
}

/// The legal route from launch to `stage`.
private func route(to stage: GuidanceFlowStage) -> [GuidanceFlowStage] {
    switch stage {
    case .idle: []
    case .acquiringPanel: [.acquiringPanel]
    case .detecting: [.acquiringPanel, .detecting]
    case .selectingTarget(let map): [.acquiringPanel, .detecting, .selectingTarget(map)]
    case .guiding(let button): [.acquiringPanel, .detecting, .selectingTarget(map), .guiding(button)]
    case .finished(let outcome): [.acquiringPanel, .detecting, .selectingTarget(map), .guiding(start), .finished(outcome)]
    }
}

private func makeFlow(at stage: GuidanceFlowStage) async throws -> (GuidanceFlow, Announcements) {
    let said = Announcements()
    let flow = GuidanceFlow { await said.record($0) }
    for step in route(to: stage) {
        let moved = await flow.advanceIfLegal(to: step)
        try #require(moved, "route to \(stage) blocked at \(step)")
    }
    return (flow, said)
}

@Suite("GuidanceFlow state machine")
struct GuidanceFlowTests {

    @Test("a new flow starts idle")
    func startsIdle() async {
        #expect(await GuidanceFlow { _ in }.currentStage() == .idle)
    }

    @Test("the happy path runs from launch to arrival, announcing every step")
    func happyPath() async throws {
        let (flow, said) = try await makeFlow(at: .finished(.arrived))
        #expect(await flow.currentStage() == .finished(.arrived))
        #expect(await said.lines.count == 5)
    }

    @Test("every move is legal or illegal exactly as the table says", arguments: everyStage)
    func transitionTable(from: GuidanceFlowStage) async throws {
        for to in everyStage {
            let (flow, said) = try await makeFlow(at: from)
            let before = await said.lines.count
            let moved = await flow.advanceIfLegal(to: to)
            let legal = expectedLegal(from, to)

            #expect(moved == legal, "\(from.kind) → \(to)")
            #expect(GuidanceFlow.isLegal(from: from, to: to) == legal)
            #expect(await flow.currentStage() == (legal ? to : from))
            // Illegal moves are silent; legal ones say exactly one thing.
            #expect(await said.lines.count == before + (legal ? 1 : 0))
        }
    }

    @Test("the documented retries are legal")
    func retries() {
        #expect(GuidanceFlow.isLegal(from: .finished(.arrived), to: .acquiringPanel))
        #expect(GuidanceFlow.isLegal(from: .finished(.lostTracking), to: .guiding(start)))
        #expect(GuidanceFlow.isLegal(from: .detecting, to: .acquiringPanel))
        #expect(GuidanceFlow.isLegal(from: .selectingTarget(map), to: .acquiringPanel))
    }

    @Test("guiding cannot jump straight to a different target")
    func noTargetSwap() {
        #expect(!GuidanceFlow.isLegal(from: .guiding(start), to: .guiding(popcorn)))
        #expect(GuidanceFlow.isLegal(from: .finished(.arrived), to: .guiding(popcorn)))
    }

    @Test("cancel returns to idle from every stage", arguments: everyStage)
    func cancelFromAnywhere(stage: GuidanceFlowStage) async throws {
        let (flow, _) = try await makeFlow(at: stage)
        let moved = await flow.cancel()
        #expect(moved == (stage != .idle))
        #expect(await flow.currentStage() == .idle)
    }

    @Test("advance(to:) ignores an illegal move")
    func advanceIgnoresIllegal() async {
        let flow = GuidanceFlow { _ in }
        await flow.advance(to: .guiding(start))
        #expect(await flow.currentStage() == .idle)
        await flow.advance(to: .acquiringPanel)
        #expect(await flow.currentStage() == .acquiringPanel)
    }

    @Test("copies of a flow share one stage")
    func copiesShareState() async {
        let flow = GuidanceFlow { _ in }
        let copy = flow
        await copy.advance(to: .acquiringPanel)
        #expect(await flow.currentStage() == .acquiringPanel)
    }

    @Test("stages() starts with the current stage and follows every move")
    func stageStream() async throws {
        let (flow, _) = try await makeFlow(at: .acquiringPanel)
        var stream = flow.stages().makeAsyncIterator()
        #expect(await stream.next() == .acquiringPanel)
        await flow.advance(to: .detecting)
        await flow.advance(to: .guiding(start))   // illegal, not delivered
        await flow.advance(to: .selectingTarget(map))
        #expect(await stream.next() == .detecting)
        #expect(await stream.next() == .selectingTarget(map))
    }
}

@Suite("GuidanceFlow announcements")
struct GuidanceFlowAnnouncementTests {

    let flow = GuidanceFlow { _ in }

    @Test("every stage has something to say", arguments: everyStage + [.selectingTarget(.empty)])
    func nonEmpty(stage: GuidanceFlowStage) {
        let line = flow.announcement(for: stage)
        #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty)
        // Heard, not read: keep each one to a breath or two.
        #expect(line.count < 140, "too long to hear: \(line)")
    }

    @Test("the four outcomes sound different")
    func outcomesAreDistinct() {
        let lines = OutcomeSignal.allCases.map { flow.announcement(for: .finished($0)) }
        #expect(Set(lines).count == OutcomeSignal.allCases.count)
    }

    @Test("every stage kind says something different")
    func stagesAreDistinct() {
        let lines = everyStage.map { flow.announcement(for: $0) }
        #expect(Set(lines).count == everyStage.count)
    }

    @Test("selecting a target says how many controls and how to choose")
    func selectingCountsControls() {
        let line = flow.announcement(for: .selectingTarget(map))
        #expect(line.contains("6 controls"))
        #expect(line.localizedCaseInsensitiveContains("say a button"))
        #expect(flow.announcement(for: .selectingTarget(.empty)).localizedCaseInsensitiveContains("scan again"))
    }

    @Test("guiding names the target, or where it is when it has no label")
    func guidingNamesTarget() {
        #expect(flow.announcement(for: .guiding(start)).contains("Start"))
        let unlabelled = SurfaceMap.Button(label: nil, bounds: PanelRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1),
                                           confidence: 0.9)
        #expect(flow.announcement(for: .guiding(unlabelled)).contains("unlabelled control at the top left"))
    }

    @Test("advancing says the new stage's announcement")
    func advanceSpeaks() async throws {
        let (flow, said) = try await makeFlow(at: .detecting)
        await flow.advance(to: .selectingTarget(map))
        #expect(await said.lines.last == flow.announcement(for: .selectingTarget(map)))
    }
}
