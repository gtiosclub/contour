//
//  LabelAssignmentTests.swift
//  SurfaceUnderstandingTests — Surface / Labels
//
//  The rules for which words belong to which key, on hand-placed words. No
//  Vision here, so these run on CI.
//

import ContourCore
import Testing
@testable import SurfaceUnderstanding

/// A word `height` tall with its top-left corner at (x, y), in panel space.
private func word(_ text: String, x: Double, y: Double, width: Double = 0.08, height: Double = 0.03) -> LabelReader.Word {
    LabelReader.Word(text: text, left: x, right: x + width, top: y, bottom: y + height)
}

@Test("a key with nothing inside takes the label printed just below it")
func keyTakesTheLabelBelowIt() {
    let key = PanelRect(x: 0.1, y: 0.5, width: 0.1, height: 0.08)
    let start = word("START", x: 0.11, y: 0.59)

    let result = LabelReader.assign([start], to: [key])

    #expect(result.labels == ["START"])
    #expect(result.unused.isEmpty)
}

@Test("text inside a key wins over text below it")
func textInsideWins() {
    let key = PanelRect(x: 0.1, y: 0.5, width: 0.1, height: 0.08)
    let inside = word("5", x: 0.13, y: 0.52, width: 0.02)
    let below = word("Memory", x: 0.11, y: 0.59)

    let result = LabelReader.assign([inside, below], to: [key])

    #expect(result.labels == ["5"])
    #expect(result.unused == [below])
}

@Test("text far below a key, or off to the side, isn't taken")
func farTextIsNotTaken() {
    let key = PanelRect(x: 0.1, y: 0.5, width: 0.1, height: 0.08)
    let farBelow = word("Clock", x: 0.11, y: 0.70)
    let toTheSide = word("Timer", x: 0.40, y: 0.59)

    let result = LabelReader.assign([farBelow, toTheSide], to: [key])

    #expect(result.labels == [nil])
    #expect(result.unused.count == 2)
}

@Test("a box holding several separate labels is a frame and gives them back")
func frameGivesItsLabelsBack() {
    let frame = PanelRect(x: 0, y: 0, width: 0.6, height: 0.4)
    let popcorn = word("Popcorn", x: 0.05, y: 0.05)
    let pizza = word("Pizza", x: 0.40, y: 0.05)

    let result = LabelReader.assign([popcorn, pizza], to: [frame])

    #expect(result.frames == [0])
    #expect(result.labels == [nil])
    #expect(Set(result.unused.map(\.text)) == ["Popcorn", "Pizza"])
}

@Test("words on one line with small gaps are one label")
func oneLineIsOneLabel() {
    let words = [word("Add", x: 0.10, y: 0.5, width: 0.04), word("30", x: 0.15, y: 0.5, width: 0.03),
                 word("Sec", x: 0.19, y: 0.5, width: 0.04)]

    let buttons = LabelReader.textButtons(from: words)

    #expect(buttons.map(\.label) == ["Add 30 Sec"])
}

@Test("a label stacked on two lines is one label")
func stackedLinesAreOneLabel() {
    let words = [word("Dinner", x: 0.10, y: 0.50), word("Plate", x: 0.11, y: 0.535, width: 0.06)]

    let buttons = LabelReader.textButtons(from: words)

    #expect(buttons.map(\.label) == ["Dinner Plate"])
}

@Test("labels a key-width apart stay separate, and their areas don't overlap")
func separateLabelsStaySeparate() {
    let words = [word("Popcorn", x: 0.05, y: 0.5), word("Potato", x: 0.25, y: 0.5),
                 word("Pizza", x: 0.45, y: 0.5), word("Reheat", x: 0.25, y: 0.6)]

    let buttons = LabelReader.textButtons(from: words)

    #expect(Set(buttons.map(\.label)) == ["Popcorn", "Potato", "Pizza", "Reheat"])
    for (i, a) in buttons.enumerated() {
        for b in buttons[(i + 1)...] {
            let overlaps = a.bounds.minX < b.bounds.maxX && b.bounds.minX < a.bounds.maxX
                && a.bounds.minY < b.bounds.maxY && b.bounds.minY < a.bounds.maxY
            #expect(!overlaps, "\(a.label) overlaps \(b.label)")
        }
    }
}

@Test("each text button covers its words")
func textButtonCoversItsWords() throws {
    let words = [word("Add", x: 0.10, y: 0.5, width: 0.04), word("30", x: 0.15, y: 0.5, width: 0.03)]

    let button = try #require(LabelReader.textButtons(from: words).first)

    #expect(words.allSatisfy { button.bounds.contains($0.centre) })
}

@Test("punctuation on its own never becomes a button")
func punctuationIsNotAButton() {
    let words = [word("•", x: 0.10, y: 0.5, width: 0.01), word("—", x: 0.40, y: 0.5, width: 0.02)]

    #expect(LabelReader.textButtons(from: words).isEmpty)
}

@Test("Reading order keeps Add 30 Sec together")
func neat1ReadingOrder() {
    let add = word("Add",x: 0.314,y: 0.700,width: 0.037,height: 0.0131)
    let thirty = word("30",x: 0.3076,y: 0.712,width: 0.021,height: 0.0118)
    let sec = word("Sec",x: 0.3304,y: 0.712,width: 0.034,height: 0.0118)

    #expect(
        LabelReader.readingOrder([sec, thirty, add]).map(\.text)
            == ["Add", "30", "Sec"]
    )
}

@Test("Words with close vertical centres stay on one line")
func closeVerticalCentresStayOnOneLine() {
    let start = word("Start", x: 0.10, y: 0.5059, width: 0.07, height: 0.012)
    let pause = word("Pause", x: 0.175, y: 0.5000, width: 0.07, height: 0.012)

    let buttons = LabelReader.textButtons(from: [pause, start])

    #expect(buttons.map(\.label) == ["Start Pause"])
}

@Test("a clock and words inside its display are removed, but Express Cook stays")
func clockDisplayWordsAreRemoved() {
    let clock = word("300", x: 0.40, y: 0.20, width: 0.16, height: 0.056)
    let displayStart = word("Start", x: 0.52, y: 0.235, width: 0.06, height: 0.012)
    let express = word("Express", x: 0.40, y: 0.30, width: 0.08, height: 0.018)
    let cook = word("Cook", x: 0.49, y: 0.30, width: 0.05, height: 0.018)

    let remaining = LabelReader.removingClockWords(
        from: [clock, displayStart, express, cook]
    )

    #expect(remaining.map(\.text) == ["Express", "Cook"])
    #expect(LabelReader.textButtons(from: remaining).map(\.label) == ["Express Cook"])
}

@Test("a long barcode is not mistaken for a clock")
func barcodeIsNotAClock() {
    let barcode = word(
        "0000017272",
        x: 0.30, y: 0.10,
        width: 0.20, height: 0.056
    )

    let words = [
        barcode,
        word("Popcorn", x: 0.10, y: 0.20, height: 0.018),
        word("Beverage", x: 0.30, y: 0.20, height: 0.018),
        word("Defrost", x: 0.50, y: 0.20, height: 0.018),
        word("Start", x: 0.40, y: 0.30, height: 0.018)
    ]

    let remaining = LabelReader.removingClockWords(from: words)

    #expect(remaining.count == words.count)
    #expect(remaining.contains(where: { $0.text == "0000017272" }))
    #expect(remaining.contains(where: { $0.text == "Start" }))
}

@Test("words outside the clock columns remain")
func wordsOutsideClockColumnsRemain() {
    let clock = word("3:00", x: 0.40, y: 0.20, width: 0.16, height: 0.056)
    let pizza = word("Pizza", x: 0.20, y: 0.22, height: 0.018)
    let potato = word("Potato", x: 0.62, y: 0.22, height: 0.018)

    let remaining = LabelReader.removingClockWords(from: [clock, pizza, potato])

    #expect(remaining.map(\.text).sorted() == ["Pizza", "Potato"])
}

@Test("microwave-08: display text is removed but Express Cook stays")
func microwave08DisplayTextIsNotAButton() {
    let words = [
        word("GA", x: 0.251, y: 0.016, width: 0.069, height: 0.015),
        word("TECH", x: 0.317, y: 0.015, width: 0.107, height: 0.016),
        word("HOUSING", x: 0.422, y: 0.011, width: 0.179, height: 0.019),
        word("0000017272", x: 0.282, y: 0.059, width: 0.299, height: 0.025),
        word("300", x: 0.387, y: 0.194, width: 0.326, height: 0.056),
        word("Cook", x: 0.204, y: 0.245, width: 0.087, height: 0.014),
        word("Time", x: 0.405, y: 0.246, width: 0.082, height: 0.012),
        word("Start", x: 0.598, y: 0.247, width: 0.088, height: 0.016),
        word("Express", x: 0.416, y: 0.395, width: 0.185, height: 0.027),
        word("Cook", x: 0.599, y: 0.396, width: 0.130, height: 0.024),
        word("1", x: 0.390, y: 0.433, width: 0.041, height: 0.017),
        word("2", x: 0.523, y: 0.433, width: 0.052, height: 0.019),
        word("5", x: 0.528, y: 0.480, width: 0.047, height: 0.020),
        word("6", x: 0.671, y: 0.482, width: 0.041, height: 0.018),
        word("7", x: 0.390, y: 0.527, width: 0.043, height: 0.018),
        word("8", x: 0.523, y: 0.528, width: 0.053, height: 0.019),
        word("9", x: 0.668, y: 0.528, width: 0.048, height: 0.020),
        word("display", x: 0.506, y: 0.609, width: 0.116, height: 0.016),
        word("on/aft", x: 0.508, y: 0.621, width: 0.111, height: 0.016)
    ]

    let buttons = LabelReader.textButtons(from: words)
    let labels = buttons.map(\.label)

    #expect(!labels.contains { $0.localizedCaseInsensitiveContains("start") })
    #expect(labels.contains("Express Cook"))
}

@Test("a separate digit on the clock row is removed")
func splitClockDigitIsRemoved() {
    let words = [
        word("12:0", x: 0.40, y: 0.20, width: 0.16, height: 0.056),
        word("1", x: 0.58, y: 0.20, width: 0.03, height: 0.056),
        word("Start", x: 0.40, y: 0.30, height: 0.018),
        word("Express", x: 0.40, y: 0.40, height: 0.018),
        word("Cook", x: 0.49, y: 0.40, height: 0.018)
    ]

    let remaining = LabelReader.removingClockWords(from: words)

    #expect(!remaining.contains(where: { $0.text == "12:0" }))
    #expect(!remaining.contains(where: { $0.text == "1" }))
    #expect(remaining.contains(where: { $0.text == "Start" }))
    #expect(Set(remaining.map(\.text)).isSuperset(of: ["Express", "Cook"]))
}

@Test("a nearly square 000 icon is not mistaken for a clock")
func nearlySquareZeroIconIsNotAClock() {
    let zeros = word("000", x: 0.35, y: 0.20,
                     width: 0.29, height: 0.295)
    let start = word("START", x: 0.35, y: 0.51, height: 0.018)
    let time = word("TIME", x: 0.45, y: 0.51, height: 0.018)
    let popcorn = word("Popcorn", x: 0.10, y: 0.60, height: 0.018)
    let defrost = word("Defrost", x: 0.60, y: 0.60, height: 0.018)

    let words = [zeros, start, time, popcorn, defrost]
    let remaining = LabelReader.removingClockWords(from: words)

    #expect(remaining.contains(where: { $0.text == "000" }))
    #expect(remaining.contains(where: { $0.text == "START" }))
    #expect(remaining.contains(where: { $0.text == "TIME" }))
}

@Test("microwave-08 at 960x1280: display text is not a button")
func microwave08ResizedDisplayTextIsNotAButton() {
    let words = [
        word("GA", x: 0.204, y: 0.018, width: 0.074, height: 0.016),
        word("TECH", x: 0.276, y: 0.016, width: 0.110, height: 0.017),
        word("HOUSING", x: 0.384, y: 0.013, width: 0.192, height: 0.020),
        word("3:00", x: 0.359, y: 0.206, width: 0.337, height: 0.062),
        word("Start", x: 0.590, y: 0.261, width: 0.074, height: 0.012),
        word("Express", x: 0.403, y: 0.413, width: 0.185, height: 0.027),
        word("Cook", x: 0.587, y: 0.414, width: 0.126, height: 0.023),
        word("display", x: 0.501, y: 0.626, width: 0.113, height: 0.014),
        word("on/aft", x: 0.511, y: 0.639, width: 0.101, height: 0.014)
    ]

    let labels = LabelReader.textButtons(from: words).map(\.label)

    #expect(!labels.contains {
        $0.localizedCaseInsensitiveContains("start")
    })
    #expect(labels.contains("Express Cook"))
}

@Test("oven1_glare: keys above the clock are preserved")
func oven1GlarePreservesKeysAboveClock() {
    let words = [
        word("WARM", x: 0.145, y: 0.589, width: 0.059, height: 0.055),
        word("COOK", x: 0.283, y: 0.613, width: 0.058, height: 0.060),
        word("TIME", x: 0.289, y: 0.675, width: 0.045, height: 0.054),
        word("TIMER", x: 0.568, y: 0.617, width: 0.059, height: 0.056),
        word("SET", x: 0.553, y: 0.679, width: 0.033, height: 0.059),
        word("OFF", x: 0.601, y: 0.674, width: 0.041, height: 0.059),
        word("0008", x: 0.273, y: 0.715, width: 0.357, height: 0.281)
    ]

    let labels = LabelReader.textButtons(from: words).map(\.label)

    #expect(labels.contains("WARM"))
    #expect(labels.contains("COOK TIME"))
    #expect(labels.contains("TIMER SET OFF"))
}
