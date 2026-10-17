//
//  Issue12MocksTests.swift
//  ContourMocks
//
//  Issue #12: the keypad map, GuidanceMath, MockRun-driven tracking and the
//  chained guidance stream. As with the rest of this target, the point is to
//  pin determinism: if a number here changes, it changes every consumer's
//  fixtures, so change it on purpose.
//

import ContourCore
import Foundation
import Testing
@testable import ContourMocks

private typealias Key = MockSurfaceMaps.KeypadButton

@Suite("Issue #12 keypad map")
struct KeypadMapTests {

    @Test("six buttons: Start, Stop, Popcorn, +30s, Defrost and an icon-only Cancel")
    func shape() {
        let map = MockSurfaceMaps.microwaveKeypad

        #expect(map.buttons.count == 6)
        #expect(Set(map.buttons.map(\.id)).count == 6)
        #expect(Set(map.buttons.compactMap(\.label)) == ["Start", "Stop", "Popcorn", "+30s", "Defrost"])
        #expect(map.buttons.filter { $0.label == nil }.map(\.id) == [Key.cancel.id])
        #expect(map.buttons.allSatisfy { $0.bounds.center.isOnPanel })
    }

    @Test("confidences are uneven and pinned")
    func confidences() {
        #expect(MockSurfaceMaps.keypadButton(.start).confidence == 0.94)
        #expect(MockSurfaceMaps.keypadButton(.stop).confidence == 0.91)
        #expect(MockSurfaceMaps.keypadButton(.popcorn).confidence == 0.72)
        for key in [Key.addThirtySeconds, .defrost, .cancel] {
            #expect((0.80...0.95).contains(MockSurfaceMaps.keypadButton(key).confidence))
        }
    }

    @Test("a 2x3 grid with no overlaps, y measured downward")
    func grid() {
        let buttons = MockSurfaceMaps.microwaveKeypad.buttons
        #expect(Set(buttons.map(\.bounds.minY)).count == 2)
        #expect(Set(buttons.map(\.bounds.minX)).count == 3)
        #expect(MockSurfaceMaps.keypadButton(.popcorn).bounds.maxY
                < MockSurfaceMaps.keypadButton(.start).bounds.minY,
                "Popcorn is on the top row, so it has the smaller y")
        for a in buttons {
            for b in buttons where a.id != b.id {
                let separated = a.bounds.maxX <= b.bounds.minX || b.bounds.maxX <= a.bounds.minX
                    || a.bounds.maxY <= b.bounds.minY || b.bounds.maxY <= a.bounds.minY
                #expect(separated)
            }
        }
    }

    @Test("the keypad is additive: the original microwave is unchanged")
    func originalMicrowaveUntouched() {
        let original = MockSurfaceMaps.microwave
        #expect(original.buttons.allSatisfy { $0.label != nil })
        #expect(original.button(labelled: "Defrost")?.confidence == 0.61)
        #expect(Set(original.buttons.map(\.id)).isDisjoint(with: Key.allCases.map(\.id)))
        #expect(MockSurfaceUnderstanding().map == original)
    }
}
