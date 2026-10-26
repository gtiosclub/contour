//
//  PanelReadoutTests.swift
//  SurfaceUnderstandingTests
//
//  Spoken panel summaries and display decisions. Most tests avoid Vision so
//  they remain deterministic on CI.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

private func readoutWord(
    _ text: String,
    x: Double,
    y: Double,
    width: Double = 0.08,
    height: Double = 0.03
) -> LabelReader.Word {
    LabelReader.Word(text: text, left: x, right: x + width, top: y, bottom: y + height)
}

private func readoutMap(_ buttons: [(String?, PanelRect)]) -> SurfaceMap {
    SurfaceMap(
        buttons: buttons.map { SurfaceMap.Button(label: $0.0, bounds: $0.1, confidence: 1) },
        confidence: 1
    )
}

private func testSetSample(_ filename: String) throws -> LabelledSample {
    try #require(TestSet.loadSamples(from: Bundle.module).first { $0.id == filename })
}

@Test("microwave-01 button list matches the expected readout")
func microwave01ButtonList() throws {
    let map = try testSetSample("microwave-01.jpg").expected
    #expect(PanelReadout().buttonList(for: map) ==
        "24 buttons. Top row: Time Cook, Defrost Weight Time, Add 30 Sec. Then Power, Clock, Kitchen Timer. Then Popcorn, Potato, Pizza. Then Frozen Vegetable, Beverage, Dinner Plate. Then the number pad, 1 to 9 and 0. Bottom row: Cancel Off, Start Pause.")
}

@Test("microwave-08 puts the left column beside its number pad")
func microwave08ButtonList() throws {
    let map = try testSetSample("microwave-08.jpg").expected
    #expect(PanelReadout().buttonList(for: map) ==
        "26 buttons. Top row: Popcorn, Time Cook, Defrost Time Weight. Then Beverage, Power Level, Timer. Then the number pad, 1 to 9 and 0, with Vegetable, Potato, Chicken, Fish on its left. Then Clock, AM PM. Then Reheat. Bottom row: Add 30 Sec, Start Pause, Cancel Off.")
}

@Test("all hand-labelled button lists stay below 50 words")
func allTestSetButtonListsAreShort() throws {
    for sample in try TestSet.loadSamples(from: Bundle.module) {
        let list = PanelReadout().buttonList(for: sample.expected)
        #expect(list.split(whereSeparator: \.isWhitespace).count < 50, "\(sample.id): \(list)")
    }
}

@Test("real panel labels apply display, barcode, merged-text, and partial-pad rules")
func realPanelLabelRules() {
    let neat = PanelReadout().buttonList(for: RealPanelLabels.map("Neat1.jpeg"))
    #expect(neat.hasPrefix("29 buttons."))
    #expect(!neat.contains("3:00"))
    #expect(!neat.contains("0000017272"))
    #expect(neat.contains("the number pad, 1, 2, 4, 5, 6, 7, 8, 9"))

    let sticker = PanelReadout().buttonList(for: RealPanelLabels.map("microwave1_neat.heif"))
    #expect(sticker.hasPrefix("22 buttons."))
    #expect(!sticker.contains("Please It do will not damage"))
}

@Test("small maps use natural singular, unread, and empty messages")
func smallMapMessages() {
    let rect = PanelRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
    #expect(PanelReadout().buttonList(for: readoutMap([("Start", rect)])) == "1 button. Start.")
    #expect(PanelReadout().buttonList(for: readoutMap([("Start", rect), (nil, rect)])) ==
        "2 buttons. Start. And 1 I can't read.")
    #expect(PanelReadout().buttonList(for: readoutMap([(nil, rect), ("", rect), (nil, rect)])) ==
        "3 buttons, but I can't read any of them.")
    #expect(PanelReadout().buttonList(for: .empty) == "I can't find any buttons.")
}

@Test("two digit keys remain ordinary keys in a single row")
func twoDigitsAreNotANumberPad() {
    let map = readoutMap([
        ("1", PanelRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)),
        ("2", PanelRect(x: 0.3, y: 0.2, width: 0.1, height: 0.1)),
    ])
    let list = PanelReadout().buttonList(for: map)
    #expect(list == "2 buttons. 1, 2.")
    #expect(!list.contains("Top row:"))
}

@Test("a key to the right of the number pad is spoken with it")
func keyOnNumberPadRight() {
    let map = readoutMap([
        ("1", PanelRect(x: 0.1, y: 0.1, width: 0.1, height: 0.08)),
        ("2", PanelRect(x: 0.1, y: 0.2, width: 0.1, height: 0.08)),
        ("3", PanelRect(x: 0.1, y: 0.3, width: 0.1, height: 0.08)),
        ("Start", PanelRect(x: 0.4, y: 0.2, width: 0.2, height: 0.08)),
    ])
    #expect(PanelReadout().buttonList(for: map) ==
        "4 buttons. The number pad, 1, 2, 3, with Start on its right.")
}

@Test("speech cleanup removes slashes, extra spaces, and trailing punctuation")
func labelSpeechCleanup() {
    let map = readoutMap([("  START/PAUSE   →vûsec.  ", PanelRect(x: 0, y: 0, width: 1, height: 1))])
    let list = PanelReadout().buttonList(for: map)
    #expect(list == "1 button. START PAUSE →vûsec.")
    #expect(!list.hasSuffix(".."))
}

private func microwave08Words(clockText: String?) -> [LabelReader.Word] {
    var words = [
        readoutWord("GA", x: 0.251, y: 0.016, width: 0.069, height: 0.015),
        readoutWord("TECH", x: 0.317, y: 0.015, width: 0.107, height: 0.016),
        readoutWord("HOUSING", x: 0.422, y: 0.011, width: 0.179, height: 0.019),
        readoutWord("0000017272", x: 0.282, y: 0.059, width: 0.299, height: 0.025),
        readoutWord("Cook", x: 0.204, y: 0.245, width: 0.087, height: 0.014),
        readoutWord("Time", x: 0.405, y: 0.246, width: 0.082, height: 0.012),
        readoutWord("Start", x: 0.598, y: 0.247, width: 0.088, height: 0.016),
        readoutWord("Express", x: 0.416, y: 0.395, width: 0.185, height: 0.027),
        readoutWord("Cook", x: 0.599, y: 0.396, width: 0.130, height: 0.024),
    ]
    if let clockText {
        words.insert(readoutWord(clockText, x: 0.387, y: 0.194, width: 0.326, height: 0.056), at: 4)
    }
    return words
}

@Test("display text normalizes valid clock readings and rejects incomplete ones")
func displayTextDecisions() {
    #expect(PanelReadout.displayText(from: microwave08Words(clockText: "300")) == "3:00")
    #expect(PanelReadout.displayText(from: microwave08Words(clockText: "12.03")) == "12:03")
    #expect(PanelReadout.displayText(from: microwave08Words(clockText: "03:00")) == "3:00")
    #expect(PanelReadout.displayText(from: microwave08Words(clockText: "13:0")) == nil)
    #expect(PanelReadout.displayText(from: microwave08Words(clockText: nil)) == nil)
    #expect(PanelReadout.displayText(from: []) == nil)
}

@Test("resized microwave-08 display reads 3:00")
func resizedDisplayText() {
    let words = [
        readoutWord("GA", x: 0.204, y: 0.018, width: 0.074, height: 0.016),
        readoutWord("TECH", x: 0.276, y: 0.016, width: 0.110, height: 0.017),
        readoutWord("HOUSING", x: 0.384, y: 0.013, width: 0.192, height: 0.020),
        readoutWord("3:00", x: 0.359, y: 0.206, width: 0.337, height: 0.062),
        readoutWord("Start", x: 0.590, y: 0.261, width: 0.074, height: 0.012),
        readoutWord("Express", x: 0.403, y: 0.413, width: 0.185, height: 0.027),
        readoutWord("Cook", x: 0.587, y: 0.414, width: 0.126, height: 0.023),
    ]
    #expect(PanelReadout.displayText(from: words) == "3:00")
}

@Test("synthetic displays are read aloud",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      .serialized,
      TextRecognitionCheck.timeLimit,
      arguments: ["1:30", "12:45"])
func syntheticDisplay(time: String) async throws {
    let reading = await PanelReadout().readDisplay(
        in: try SyntheticPanel.displayPhoto(time: time),
        panel: .fullFrame
    )
    #expect(reading.spoken == "The display says \(time).")
}

@Test("synthetic panels without displays report failure",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func syntheticMissingDisplay() async throws {
    let readout = PanelReadout()
    #expect(await readout.readDisplay(in: try SyntheticPanel.displayPhoto(time: nil), panel: .fullFrame).spoken ==
        "I can't read the display.")
    #expect(await readout.readDisplay(in: try SyntheticPanel.photo(), panel: .fullFrame).spoken ==
        "I can't read the display.")
}
