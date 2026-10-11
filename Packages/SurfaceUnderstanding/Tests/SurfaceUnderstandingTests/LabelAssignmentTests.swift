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
