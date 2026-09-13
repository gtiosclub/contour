//
//  ContourCoreTests.swift
//  ContourCore
//
//  These tests pin the coordinate convention itself. If one of them starts
//  failing, either the convention changed (needs all four leads) or someone
//  flipped an axis by accident. Both are worth stopping for.
//

import Foundation
import Testing
@testable import ContourCore

@Suite("Coordinate convention")
struct CoordinateConventionTests {

    @Test("y increases downward, x increases rightward")
    func axesPointTheRightWay() {
        let topLeft = PanelPoint(x: 0, y: 0)
        let bottomRight = PanelPoint(x: 1, y: 1)

        let v = topLeft.vector(to: bottomRight)
        #expect(v.dx > 0, "x must increase to the right")
        #expect(v.dy > 0, "y must increase DOWNWARD — see COORDINATES.md")
    }

    @Test("a rect's origin is its top-left corner")
    func rectOriginIsTopLeft() {
        let rect = PanelRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)

        #expect(rect.minY == 0.3)
        #expect(rect.maxY == 0.5)
        #expect(rect.center == PanelPoint(x: 0.4, y: 0.4))
        #expect(rect.contains(rect.center))
        #expect(!rect.contains(PanelPoint(x: 0.2, y: 0.1)), "above the rect is outside it")
    }

    @Test("points off the panel are representable and not clamped")
    func offPanelPointsSurvive() {
        let aboveTheEdge = PanelPoint(x: 0.5, y: -0.08)

        #expect(!aboveTheEdge.isOnPanel)
        #expect(aboveTheEdge.y == -0.08, "off-panel values must not be clamped")
    }

    @Test("vector magnitude and normalization")
    func vectorMath() {
        let v = PanelVector(dx: 3, dy: 4)
        #expect(v.magnitude == 5)
        #expect(v.normalized?.magnitude ?? 0 == 1)
        #expect(PanelVector.zero.normalized == nil)
    }
}

@Suite("Contract types")
struct ContractTypeTests {

    @Test("OutcomeSignal has exactly four cases")
    func fourOutcomes() {
        #expect(OutcomeSignal.allCases.count == 4)
        #expect(Set(OutcomeSignal.allCases) == [.arrived, .lostTracking, .notFound, .lowConfidence])
    }

    @Test("a lost frame asserts nothing")
    func lostFrameIsEmpty() {
        let frame = TrackingFrame.lost(at: Date(timeIntervalSince1970: 0))

        #expect(frame.fingertip == nil)
        #expect(frame.trackingQuality == .lost)
        #expect(frame.panel.confidence == 0)
    }

    @Test("SurfaceMap looks buttons up by point and by label")
    func surfaceMapLookup() {
        let start = SurfaceMap.Button(
            label: "Start",
            bounds: PanelRect(x: 0.6, y: 0.6, width: 0.2, height: 0.15),
            confidence: 0.9
        )
        let map = SurfaceMap(buttons: [start], confidence: 0.88)

        #expect(map.button(at: start.bounds.center)?.id == start.id)
        #expect(map.button(at: PanelPoint(x: 0.05, y: 0.05)) == nil)
        #expect(map.button(labelled: "start")?.id == start.id, "lookup is case-insensitive")
        #expect(map.button(labelled: "Defrost") == nil)
    }

    @Test("contract types round-trip through Codable")
    func codableRoundTrip() throws {
        let state = GuidanceState(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            vector: GuidanceVector(
                direction: PanelVector(dx: 0, dy: 1),
                normalizedDistance: 0.42
            ),
            outcome: .lowConfidence
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GuidanceState.self, from: data)

        #expect(decoded == state)
    }
}
