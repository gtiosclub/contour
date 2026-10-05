//
//  ButtonLookupTests.swift
//  ContourTests
//
//  Which button a spoken request names, on labels the way our microwaves read.
//

import ContourCore
import Testing
@testable import ContourApp

private func map(_ labels: [String?]) -> SurfaceMap {
    SurfaceMap(buttons: labels.enumerated().map { i, label in
        SurfaceMap.Button(label: label, bounds: PanelRect(x: Double(i) * 0.1, y: 0, width: 0.09, height: 0.1),
                          confidence: 1)
    }, confidence: 1)
}

@Suite("Spoken requests to buttons")
struct ButtonLookupTests {
    // Labels from microwave-01 in the test set, including a key read off two
    // lines as "Start Pause".
    let microwave = map(["Start Pause", "Cancel/Off", "Popcorn", "Clock", "Kitchen Timer", "5", "Add 30 Sec", nil])

    @Test("start finds the key read as \"Start Pause\"", arguments: ["start", "Start", "press start please", "go"])
    func startFindsStartPause(request: String) {
        #expect(ButtonLookup.button(for: request, in: microwave)?.label == "Start Pause")
    }

    @Test("a plain label still matches")
    func plainLabel() {
        #expect(ButtonLookup.button(for: "popcorn", in: microwave)?.label == "Popcorn")
    }

    @Test("a spoken number finds the digit key")
    func spokenNumber() {
        #expect(ButtonLookup.button(for: "five", in: microwave)?.label == "5")
    }

    @Test("the shortest label wins: Start beats Start Time")
    func shortestWins() {
        #expect(ButtonLookup.button(for: "start", in: map(["Start Time", "Start"]))?.label == "Start")
    }

    @Test("something that isn't on the panel finds nothing")
    func notOnThePanel() {
        #expect(ButtonLookup.button(for: "defrost", in: microwave) == nil)
        #expect(ButtonLookup.button(for: "please", in: microwave) == nil)
    }
}
