//
//  PanelReadout.swift
//  SurfaceUnderstanding — Surface / Readout
//
//  Short spoken descriptions of a panel's buttons and display.
//

import ContourCore
import Foundation

public struct PanelReadout: Sendable {
    public struct DisplayReading: Hashable, Sendable {
        /// What the display shows, like "1:30". `nil` when it couldn't be read.
        public var text: String?

        /// "The display says 1:30." or "I can't read the display."
        public var spoken: String {
            text.map { "The display says \($0)." } ?? "I can't read the display."
        }

        public init(text: String?) {
            self.text = text
        }
    }

    private struct Item {
        var spoken: String
        var bounds: PanelRect
        var isNumberPad = false
    }

    public init() {}

    /// Answers "What buttons are there?" without running Vision.
    public func buttonList(for map: SurfaceMap) -> String {
        var items: [Item] = []
        var unreadCount = 0

        for button in map.buttons {
            guard let rawLabel = button.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawLabel.isEmpty else {
                unreadCount += 1
                continue
            }
            guard Self.canBeAKey(rawLabel) else { continue }
            items.append(Item(spoken: Self.spokenLabel(rawLabel), bounds: button.bounds))
        }

        let buttonCount = items.count + unreadCount
        guard buttonCount > 0 else { return "I can't find any buttons." }
        guard !items.isEmpty else {
            return "\(buttonCount) buttons, but I can't read any of them."
        }

        items = Self.consolidatingNumberPad(in: items)
        let rows = Self.rows(from: items)
        let countSentence = "\(buttonCount) \(buttonCount == 1 ? "button" : "buttons")."
        var sentences = [countSentence]

        if rows.count == 1 {
            if rows[0].count == 1, let pad = rows[0].first, pad.isNumberPad {
                sentences.append("\(pad.spoken.prefix(1).uppercased())\(pad.spoken.dropFirst()).")
            } else {
                sentences.append("\(rows[0].map(\.spoken).joined(separator: ", ")).")
            }
        } else {
            for (index, row) in rows.enumerated() {
                if row.count == 1, let pad = row.first, pad.isNumberPad {
                    if index == 0 || index == rows.count - 1 {
                        sentences.append("\(pad.spoken.prefix(1).uppercased())\(pad.spoken.dropFirst()).")
                    } else {
                        sentences.append("Then \(pad.spoken).")
                    }
                } else {
                    let prefix: String
                    if index == 0 {
                        prefix = "Top row:"
                    } else if index == rows.count - 1 {
                        prefix = "Bottom row:"
                    } else {
                        prefix = "Then"
                    }
                    sentences.append("\(prefix) \(row.map(\.spoken).joined(separator: ", ")).")
                }
            }
        }

        if unreadCount > 0 {
            sentences.append("And \(unreadCount) I can't read.")
        }
        return sentences.joined(separator: " ")
    }

    /// Answers "What does it say?" by reading the display in a fresh photo.
    public func readDisplay(in photo: PanelPhoto, panel: PanelQuad) async -> DisplayReading {
        do {
            let image = try photo.cgImage()
            let observations = try await LabelReader.recognizeText(in: image)
            let words = LabelReader().locateWords(in: observations, panel: panel).filter {
                (0...1).contains($0.centre.x) && (-0.5...1).contains($0.centre.y)
            }
            return DisplayReading(text: Self.displayText(from: words))
        } catch {
            return DisplayReading(text: nil)
        }
    }

    /// The display decision itself, separated from Vision for deterministic tests.
    static func displayText(from words: [LabelReader.Word]) -> String? {
        guard let found = LabelReader.clock(in: words)?.clock else { return nil }
        var text = found.text.replacingOccurrences(of: ".", with: ":")
        if !text.contains(":"), text.count >= 3 {
            text.insert(":", at: text.index(text.endIndex, offsetBy: -2))
        }
        guard text.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        if text.hasPrefix("0") {
            text.removeFirst()
        }
        return text
    }

    private static func canBeAKey(_ label: String) -> Bool {
        if label.range(of: #"\d:\d"#, options: .regularExpression) != nil { return false }
        let words = label.split(whereSeparator: \.isWhitespace)
        if words.count > 4 { return false }
        if label.allSatisfy(\.isNumber), label.count > 2 { return false }
        return true
    }

    private static func spokenLabel(_ label: String) -> String {
        let words = label.replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var result = words.joined(separator: " ")
        while let last = result.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func consolidatingNumberPad(in source: [Item]) -> [Item] {
        let digitIndices = source.indices.filter {
            source[$0].spoken.count == 1 && source[$0].spoken.first?.isNumber == true
        }
        let digits = Set(digitIndices.compactMap { source[$0].spoken.first })
        guard digits.count >= 3 else { return source }

        let digitItems = digitIndices.map { source[$0] }
        let padBounds = union(of: digitItems.map(\.bounds))
        var remaining = source.enumerated().compactMap { digitIndices.contains($0.offset) ? nil : $0.element }

        let sideIndices = remaining.indices.filter { index in
            let bounds = remaining[index].bounds
            return (padBounds.minY...padBounds.maxY).contains(bounds.center.y)
                && (bounds.maxX < padBounds.minX || bounds.minX > padBounds.maxX)
        }
        let left = sideIndices.filter { remaining[$0].bounds.maxX < padBounds.minX }
            .map { remaining[$0] }.sorted { $0.bounds.center.y < $1.bounds.center.y }
        let right = sideIndices.filter { remaining[$0].bounds.minX > padBounds.maxX }
            .map { remaining[$0] }.sorted { $0.bounds.center.y < $1.bounds.center.y }
        remaining = remaining.enumerated().compactMap { sideIndices.contains($0.offset) ? nil : $0.element }

        let keypadOrder = Array("1234567890")
        let digitDescription = digits == Set(keypadOrder)
            ? "1 to 9 and 0"
            : keypadOrder.filter(digits.contains).map(String.init).joined(separator: ", ")
        var spoken = "the number pad, \(digitDescription)"
        if !left.isEmpty {
            spoken += ", with \(left.map(\.spoken).joined(separator: ", ")) on its left"
        }
        if !right.isEmpty {
            spoken += ", with \(right.map(\.spoken).joined(separator: ", ")) on its right"
        }

        remaining.append(Item(spoken: spoken, bounds: padBounds, isNumberPad: true))
        return remaining
    }

    private static func rows(from items: [Item]) -> [[Item]] {
        var rows: [[Item]] = []
        for item in items.sorted(by: { $0.bounds.center.y < $1.bounds.center.y }) {
            if let last = rows.last?.last,
               abs(item.bounds.center.y - last.bounds.center.y) <= 0.5 * min(item.bounds.height, last.bounds.height) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.bounds.center.x < $1.bounds.center.x } }
    }

    private static func union(of bounds: [PanelRect]) -> PanelRect {
        let minX = bounds.map(\.minX).min() ?? 0
        let maxX = bounds.map(\.maxX).max() ?? 0
        let minY = bounds.map(\.minY).min() ?? 0
        let maxY = bounds.map(\.maxY).max() ?? 0
        return PanelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
