//
//  LabelServiceTests.swift
//  SurfaceUnderstandingTests — Surface / Option O
//
//  Exercise the server-labeling contract without Vision or a network. The fake
//  service covers successful filtering and relabeling, plus every fallback path
//  where Option O must return Option V's result unchanged.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

private struct FakeLabelService: LabelService {
    enum Mode: Sendable {
        case answer(LabelReply)
        case offline
        case slow(LabelReply)
        case malformed
    }

    let mode: Mode
    let counter: CallCounter?

    init(mode: Mode, counter: CallCounter? = nil) {
        self.mode = mode
        self.counter = counter
    }

    func label(_ request: LabelRequest) async throws -> LabelReply {
        await counter?.record()
        switch mode {
        case .answer(let reply):
            return reply
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .slow(let reply):
            try await Task.sleep(for: .seconds(5))
            return reply
        case .malformed:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Invalid label reply"
            ))
        }
    }
}

private actor CallCounter {
    private var calls = 0

    func record() {
        calls += 1
    }

    func value() -> Int {
        calls
    }
}

private func optionVFixture() throws -> (PanelPhoto, OptionVResult) {
    let photo = try SyntheticPanel.photo()
    let buttons = [
        SurfaceMap.Button(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            label: "first",
            bounds: PanelRect(x: 0.1, y: 0.1, width: 0.2, height: 0.15),
            confidence: 0.8
        ),
        SurfaceMap.Button(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            label: nil,
            bounds: PanelRect(x: 0.4, y: 0.1, width: 0.2, height: 0.15),
            confidence: 0.7
        ),
        SurfaceMap.Button(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            label: "old label",
            bounds: PanelRect(x: 0.7, y: 0.1, width: 0.2, height: 0.15),
            confidence: 0.9
        ),
    ]
    return (photo, OptionVResult(
        panel: .fullFrame,
        map: SurfaceMap(buttons: buttons, confidence: 0.6)
    ))
}

@Test("Option O drops, relabels, preserves, and selects Start")
func optionOAppliesGoodAnswer() async throws {
    let (photo, vision) = try optionVFixture()
    let service = FakeLabelService(mode: .answer(LabelReply(
        boxes: [
            LabelReply.Box(id: "b1", label: "Reject me", isButton: false),
            LabelReply.Box(id: "b2", label: "Keep me", isButton: true),
            LabelReply.Box(id: "b3", label: "Go", isButton: true),
        ],
        start: "b3"
    )))

    let result = await applyOpenAILabels(to: photo, vision: vision, using: service)

    #expect(result.buttons.count == 2)
    #expect(result.buttons[0].label == "Keep me")
    #expect(result.buttons[1].label == "Start")
    #expect(result.buttons.map(\.bounds) == [vision.map.buttons[1].bounds, vision.map.buttons[2].bounds])
}

@Test("Option O returns V unchanged when offline")
func optionOOfflineFallsBack() async throws {
    let (photo, vision) = try optionVFixture()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .offline)
    )
    #expect(result == vision.map)
}

@Test("Option O returns V unchanged when the server is slow")
func optionOSlowFallsBack() async throws {
    let (photo, vision) = try optionVFixture()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .slow(LabelReply(boxes: [], start: nil)))
    )
    #expect(result == vision.map)
}

@Test("Option O returns V unchanged for an unknown box id")
func optionOWrongIDFallsBack() async throws {
    let (photo, vision) = try optionVFixture()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .answer(LabelReply(
            boxes: [LabelReply.Box(id: "b99", label: "Unknown", isButton: true)],
            start: nil
        )))
    )
    #expect(result == vision.map)
}

@Test("Option O returns V unchanged when Start points to a rejected box")
func optionORejectedStartFallsBack() async throws {
    let (photo, vision) = try optionVFixture()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .answer(LabelReply(
            boxes: [LabelReply.Box(id: "b1", label: "Rejected", isButton: false)],
            start: "b1"
        )))
    )
    #expect(result == vision.map)
}

@Test("Option O returns V unchanged when the reply does not decode")
func optionOMalformedReplyFallsBack() async throws {
    let (photo, vision) = try optionVFixture()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .malformed)
    )
    #expect(result == vision.map)
}

@Test("Option O skips the service when V found no boxes")
func optionOEmptyVisionSkipsCall() async throws {
    let photo = try SyntheticPanel.photo()
    let vision = OptionVResult(panel: .fullFrame, map: .empty)
    let counter = CallCounter()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .malformed, counter: counter)
    )
    #expect(result == .empty)
    #expect(await counter.value() == 0)
}

@Test("Option O keeps V's label when the server sends an empty one")
func optionOEmptyLabelKeepsVisionLabel() async throws {
    let (photo, vision) = try optionVFixture()
    let result = await applyOpenAILabels(
        to: photo,
        vision: vision,
        using: FakeLabelService(mode: .answer(LabelReply(
            boxes: [LabelReply.Box(id: "b1", label: "", isButton: true)],
            start: nil
        )))
    )
    #expect(result.buttons[0].label == vision.map.buttons[0].label)
}

@Test("Option O names the Start box when it has no label from V or the server")
func optionOEmptyStartLabelBecomesStart() async throws {
    let (photo, vision) = try optionVFixture()
    var unread = vision.map
    unread.buttons[0].label = nil
    let result = await applyOpenAILabels(
        to: photo,
        vision: OptionVResult(panel: vision.panel, map: unread),
        using: FakeLabelService(mode: .answer(LabelReply(
            boxes: [LabelReply.Box(id: "b1", label: "", isButton: true)],
            start: "b1"
        )))
    )
    #expect(result.buttons[0].label == "Start")
}
