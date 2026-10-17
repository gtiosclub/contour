//
//  PanelLayoutTests.swift
//  ContourUI — Experience / Accessibility & Launch
//
//  The words a VoiceOver user hears for each control, and for each moment of
//  guidance. y is DOWN in panel space: +dy must be "down".
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import ContourUI

@Suite("Describing a panel out loud")
struct PanelLayoutTests {

    let layout = PanelLayout(map: MockSurfaceMaps.microwave)

    @Test("the microwave reads in two rows of three, top row first")
    func readingOrder() {
        #expect(layout.rowCount == 2)
        #expect(layout.entries.map { $0.button.label } ==
                ["Popcorn", "Beverage", "Defrost", "Add 30 Sec", "Start", "Stop/Clear"])
        #expect(layout.entries.map(\.row) == [1, 1, 1, 2, 2, 2])
        #expect(layout.entries.map(\.column) == [1, 2, 3, 1, 2, 3])
    }

    @Test("positions are among the controls: top left to bottom right")
    func positions() {
        #expect(layout.entries.map(\.position) ==
                ["top left", "top center", "top right", "bottom left", "bottom center", "bottom right"])
        #expect(layout.accessibilityLabel(for: layout.entries[0]) == "Popcorn, top left")
    }

    @Test("an unlabelled control is named by row and column")
    func unlabelled() throws {
        var map = MockSurfaceMaps.microwave
        map.buttons[3].label = nil   // Add 30 Sec, row 2 column 1
        let layout = PanelLayout(map: map)
        let entry = try #require(layout.entry(for: map.buttons[3].id))
        #expect(layout.title(for: entry) == "Unlabelled control, row 2 column 1")
        #expect(layout.accessibilityLabel(for: entry) == "Unlabelled control, row 2 column 1, bottom left")
    }

    @Test("a blank label counts as unlabelled")
    func blankLabel() {
        let button = SurfaceMap.Button(label: "  ", bounds: PanelRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1),
                                       confidence: 1)
        #expect(PanelLayout.spokenName(for: button) == "the unlabelled control at the bottom right")
    }

    @Test("input order does not change reading order")
    func orderIndependent() {
        let shuffled = SurfaceMap(buttons: MockSurfaceMaps.microwave.buttons.reversed(), confidence: 0.9)
        #expect(PanelLayout(map: shuffled).entries.map(\.id) == layout.entries.map(\.id))
    }

    @Test("Defrost, at 0.61, is the unsure one")
    func unsure() {
        let unsure = MockSurfaceMaps.microwave.buttons.filter(PanelLayout.isUnsure).map(\.label)
        #expect(unsure == ["Defrost"])
        #expect(PanelLayout.confidenceWording(0.61).localizedCaseInsensitiveContains("unsure"))
        #expect(PanelLayout.confidenceWording(0.97) == "Detected clearly")
        #expect(PanelLayout.confidenceWording(0.75) == "Probably right")
    }

    @Test("an empty panel has no entries")
    func empty() {
        #expect(PanelLayout(map: .empty).entries.isEmpty)
    }
}

@Suite("Guidance in words")
struct GuidanceWordingTests {

    @Test("+dy is down, -dy is up", arguments: [
        (PanelVector(dx: 0, dy: 1), "down"),
        (PanelVector(dx: 0, dy: -1), "up"),
        (PanelVector(dx: 1, dy: 0), "right"),
        (PanelVector(dx: -1, dy: 0), "left"),
        (PanelVector(dx: 0.7, dy: 0.7), "down and right"),
        (PanelVector(dx: -0.7, dy: -0.7), "up and left"),
        (PanelVector(dx: 0.7, dy: -0.7), "up and right"),
        (PanelVector(dx: -0.7, dy: 0.7), "down and left"),
        (PanelVector.zero, "on target"),
    ])
    func direction(vector: PanelVector, words: String) {
        #expect(GuidanceWording.direction(vector) == words)
    }

    @Test("the ring fills as the finger closes in, and never overflows")
    func fill() {
        #expect(GuidanceWording.proximityFill(0) == 1)
        #expect(GuidanceWording.proximityFill(1) == 0)
        #expect(GuidanceWording.proximityFill(1.4) == 0)
        #expect(GuidanceWording.proximityFill(-0.2) == 1)
        #expect(GuidanceWording.proximityFill(.nan) == 0)
        #expect(GuidanceWording.proximityFill(0.25) == 0.75)
    }

    @Test("closeness words get warmer as distance shrinks")
    func closeness() {
        let words = [0.9, 0.4, 0.2, 0.08, 0.0].map(GuidanceWording.closeness)
        #expect(Set(words).count == words.count)
        #expect(words.last == "On target")
    }
}
