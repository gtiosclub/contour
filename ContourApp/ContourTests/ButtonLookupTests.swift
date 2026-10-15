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

    @Test("start finds the key read as \"Start Pause\"",
          arguments: ["start", "Start", "the start button", "press start please", "go"])
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

    @Test("the key that says just Start wins over Start Time")
    func exactLabelWins() {
        #expect(ButtonLookup.button(for: "start", in: map(["Start Time", "Start"]))?.label == "Start")
    }

    @Test("something that isn't on the panel finds nothing")
    func notOnThePanel() {
        #expect(ButtonLookup.button(for: "defrost", in: microwave) == nil)
        #expect(ButtonLookup.button(for: "please", in: microwave) == nil)
    }

    // The old lookup fell back to matching word by word and took the shortest
    // label, which picked the wrong key on each of these. Labels are trimmed
    // from what LabelReader read off the team's photos (#78's RealPanelLabels).

    @Test("a display is not a key: \"one\" doesn't find the 1 in 1:35")
    func displayIsNotAKey() {
        let panel = map(["1:35", "Time Cook", "Popcorn", "2", "5", "Clock", "START →vûsec."])
        #expect(ButtonLookup.button(for: "one", in: panel) == nil)
    }

    @Test("start never means Delay Start")
    func startIsNotDelayStart() {
        let oven = map(["Timer Set/Off", "10:43", "Broil", "Cook Time", "Delay Start", "Clock"])
        #expect(ButtonLookup.button(for: "press start", in: oven) == nil)
    }

    @Test("text merged across the panel is not one key")
    func mergedTextIsNotAKey() {
        let glare = map([
            "Kitchen Timer", "Time Cook", "Beverage",
            "10:45 Defrost Add Weight/Time 30 Sec Power Clock Popcorn Potato Pizza Frozen Vegetable Dinner Plate Express Cook",
            "Start Pause",
        ])
        #expect(ButtonLookup.button(for: "popcorn", in: glare) == nil)
    }

    @Test("every word said is on the key: cook time is Time Cook, not Cook")
    func everyWordIsOnTheKey() {
        let panel = map(["Popcorn", "Time Cook", "Cook", "Time", "Express Cook", "Start Pause"])
        #expect(ButtonLookup.button(for: "press cook time", in: panel)?.label == "Time Cook")
    }
}
