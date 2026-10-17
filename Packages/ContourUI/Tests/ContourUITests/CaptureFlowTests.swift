//
//  CaptureFlowTests.swift
//  ContourUI — Experience / App Flow
//
//  Capture without a camera fails clearly; selection suspends until the
//  selection screen (a tap, or a spoken request) resolves it.
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import ContourUI

private let map = MockSurfaceMaps.microwave
private let start = MockSurfaceMaps.microwaveStartButton

/// Waits until a `selectTarget(in:)` call is suspended in `selection`.
private func waitUntilAwaiting(_ selection: TargetSelection) async {
    while !selection.broker.isAwaiting { await Task.yield() }
}

@Suite("CaptureFlow")
struct CaptureFlowTests {

    @Test("with no camera, capture throws noCamera instead of crashing")
    func noCamera() async {
        await #expect(throws: CaptureFlowError.noCamera) {
            try await CaptureFlow().capturePanelPhoto()
        }
    }

    @Test("an injected camera's photo comes straight through")
    func injectedCamera() async throws {
        let photo = PanelPhoto(data: Data([1, 2, 3]), pixelSize: PixelSize(width: 3, height: 1),
                               timestamp: MockTrackingSource.fixedEpoch)
        let flow = CaptureFlow { photo }
        #expect(try await flow.capturePanelPhoto() == photo)
    }
}

@Suite("TargetSelection")
struct TargetSelectionTests {

    @Test("choosing a control resolves the awaiting call with it")
    func choosingResolves() async {
        let selection = TargetSelection()
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        #expect(selection.broker.pendingMap == map)

        #expect(selection.choose(start))
        #expect(await pending.value == start)
        #expect(!selection.broker.isAwaiting)
    }

    @Test("a copy held by a view resolves the call the app is awaiting")
    func copiesShareTheBroker() async {
        let selection = TargetSelection()
        let viewCopy = selection
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(viewCopy)
        viewCopy.choose(start)
        #expect(await pending.value == start)
    }

    @Test("backing out returns nil")
    func backingOut() async {
        let selection = TargetSelection()
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        #expect(selection.backOut())
        #expect(await pending.value == nil)
    }

    @Test("a control from another panel is refused and the selection stays open")
    func foreignButtonRefused() async {
        let selection = TargetSelection()
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        let stranger = SurfaceMap.Button(label: "Start", bounds: start.bounds, confidence: 1)
        #expect(!selection.choose(stranger))
        #expect(selection.broker.isAwaiting)
        selection.backOut()
        #expect(await pending.value == nil)
    }

    @Test("choosing with nothing pending does nothing")
    func nothingPending() {
        let selection = TargetSelection()
        #expect(!selection.choose(start))
        #expect(!selection.backOut())
    }

    @Test("cancelling the awaiting task returns nil")
    func cancellation() async {
        let selection = TargetSelection()
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        pending.cancel()
        #expect(await pending.value == nil)
        #expect(!selection.broker.isAwaiting)
    }

    @Test("a newer selection supersedes the old one, which returns nil")
    func superseded() async {
        let selection = TargetSelection()
        let first = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        let second = Task { await selection.selectTarget(in: map) }
        #expect(await first.value == nil)
        await waitUntilAwaiting(selection)
        selection.choose(start)
        #expect(await second.value == start)
    }

    @Test("a spoken request that names a control resolves the selection")
    func voiceResolves() async throws {
        let selection = TargetSelection(listen: { map in map.button(labelled: "start") })
        #expect(selection.canListen)
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        #expect(try await selection.listenForTarget() == start)
        #expect(await pending.value == start)
    }

    @Test("a spoken request for nothing on the panel leaves the selection open")
    func voiceNotFound() async throws {
        let selection = TargetSelection(listen: { map in map.button(labelled: "defrost and pizza") })
        let pending = Task { await selection.selectTarget(in: map) }
        await waitUntilAwaiting(selection)
        #expect(try await selection.listenForTarget() == nil)
        #expect(selection.broker.isAwaiting)
        selection.backOut()
        #expect(await pending.value == nil)
    }

    @Test("touch-only selection cannot listen")
    func touchOnly() async throws {
        let selection = TargetSelection()
        #expect(!selection.canListen)
        #expect(try await selection.listenForTarget() == nil)
    }
}
