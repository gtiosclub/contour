//
//  PanelLayout.swift
//  ContourUI — Experience / Accessibility & Launch
//
//  How a panel is described out loud: reading order, rows and columns, "top
//  left", how sure we are, and which way to move. Pure functions over
//  ContourCore types, so the words are pinned by tests rather than discovered
//  with VoiceOver on a demo day.
//
//  COORDINATES
//  Normalized panel space: (0,0) top-left, (1,1) bottom-right, y DOWNWARD.
//  A direction with +dy means "move down". See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A panel's controls in reading order, with rows, columns and spoken names.
public struct PanelLayout: Hashable, Sendable {

    /// One control, placed in the grid.
    public struct Entry: Identifiable, Hashable, Sendable {
        public let button: SurfaceMap.Button
        /// 1-based row, top to bottom.
        public let row: Int
        /// 1-based column within its row, left to right.
        public let column: Int
        /// Where it sits among the panel's controls: "top left", "bottom center".
        public let position: String

        public var id: UUID { button.id }
    }

    /// Every control, top row first, left to right within a row.
    public let entries: [Entry]

    /// How many rows the controls form.
    public let rowCount: Int

    public init(map: SurfaceMap) {
        // Cluster into rows by centre height: a new row starts when a centre is
        // more than half a typical button height below the current row.
        let sorted = map.buttons.sorted { $0.bounds.center.y < $1.bounds.center.y }
        let heights = sorted.map(\.bounds.height).sorted()
        let typical = heights.isEmpty ? 0 : heights[heights.count / 2]
        let gap = max(typical / 2, 0.03)

        var rows: [[SurfaceMap.Button]] = []
        var rowCentre = -Double.infinity
        for button in sorted {
            let y = button.bounds.center.y
            if rows.isEmpty || y - rowCentre > gap {
                rows.append([button])
                rowCentre = y
            } else {
                rows[rows.count - 1].append(button)
                let row = rows[rows.count - 1]
                rowCentre = row.map(\.bounds.center.y).reduce(0, +) / Double(row.count)
            }
        }

        let rowCount = rows.count
        var entries: [Entry] = []
        for (rowIndex, row) in rows.enumerated() {
            let ordered = row.sorted { $0.bounds.center.x < $1.bounds.center.x }
            for (columnIndex, button) in ordered.enumerated() {
                let vertical = Self.band(index: rowIndex, count: rowCount,
                                         words: ("top", "middle", "bottom"))
                let horizontal = Self.band(index: columnIndex, count: ordered.count,
                                           words: ("left", "center", "right"))
                entries.append(Entry(button: button, row: rowIndex + 1, column: columnIndex + 1,
                                     position: Self.combine(vertical: vertical, horizontal: horizontal)))
            }
        }
        self.entries = entries
        self.rowCount = rowCount
    }

    /// The entry for `id`, if it is on this panel.
    public func entry(for id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    // MARK: Words

    /// The row's visible title: the label, or a grid position for an unlabelled
    /// control — "Unlabelled control, row 2 column 1".
    public func title(for entry: Entry) -> String {
        if let label = Self.cleanLabel(entry.button.label) { return label }
        return "Unlabelled control, row \(entry.row) column \(entry.column)"
    }

    /// What VoiceOver reads for a row: name, then where it is.
    /// "Popcorn, top left". Confidence goes in the accessibility value.
    public func accessibilityLabel(for entry: Entry) -> String {
        if entry.position.isEmpty { return title(for: entry) }
        return "\(title(for: entry)), \(entry.position)"
    }

    /// A button's name as said mid-sentence — its label, or where it is when
    /// there is no label: "the unlabelled control at the top left".
    public static func spokenName(for button: SurfaceMap.Button) -> String {
        if let label = cleanLabel(button.label) { return label }
        let words = positionWords(for: button.bounds)
        return words.isEmpty ? "the unlabelled control" : "the unlabelled control at the \(words)"
    }

    /// Where a rectangle sits on the whole panel, in thirds: "top left",
    /// "center", "bottom right". Use the layout's `Entry.position` when you have
    /// the whole map — it describes position among the controls, which is what
    /// a hand feels.
    public static func positionWords(for rect: PanelRect) -> String {
        func third(_ value: Double, _ words: (String, String, String)) -> String {
            value < 1.0 / 3 ? words.0 : value > 2.0 / 3 ? words.2 : words.1
        }
        return combine(vertical: third(rect.center.y, ("top", "middle", "bottom")),
                       horizontal: third(rect.center.x, ("left", "center", "right")))
    }

    // MARK: Confidence

    /// Below this per-button confidence a control is drawn dashed and called unsure.
    public static let unsureThreshold = 0.7

    /// Whether detection is unsure about `button`.
    public static func isUnsure(_ button: SurfaceMap.Button) -> Bool {
        button.confidence < unsureThreshold
    }

    /// How sure detection is, in words: "Detected clearly", "Probably right",
    /// "Unsure, the label may be wrong".
    public static func confidenceWording(_ confidence: Double) -> String {
        if confidence >= 0.85 { return "Detected clearly" }
        if confidence >= unsureThreshold { return "Probably right" }
        return "Unsure, the label may be wrong"
    }

    // MARK: Helpers

    private static func cleanLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Which of three words an index falls in. One item has no position on that axis.
    private static func band(index: Int, count: Int, words: (String, String, String)) -> String {
        guard count > 1 else { return "" }
        let t = Double(index) / Double(count - 1)
        return t < 1.0 / 3 ? words.0 : t > 2.0 / 3 ? words.2 : words.1
    }

    private static func combine(vertical: String, horizontal: String) -> String {
        switch (vertical, horizontal) {
        case ("middle", "center"), ("", "center"): return "center"
        case (_, ""): return vertical
        case ("", _): return horizontal
        case ("middle", _): return "middle \(horizontal)"
        default: return "\(vertical) \(horizontal)"
        }
    }
}

/// Live guidance in words and numbers, for the guide screen.
public enum GuidanceWording {

    /// Which way to move, in eight directions: "up", "down and right".
    ///
    /// `+dy` is **down** (panel space), so `(0, 1)` is "down". The zero vector
    /// is "on target".
    public static func direction(_ vector: PanelVector) -> String {
        guard vector.magnitude > 0 else { return "on target" }
        // Clockwise from right, because y is down: 0 right, 90 down.
        let degrees = vector.angle * 180 / .pi
        let sector = Int(((degrees + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return ["right", "down and right", "down", "down and left",
                "left", "up and left", "up", "up and right"][sector]
    }

    /// How close the finger is, in words, from a normalized distance.
    public static func closeness(_ distance: Double) -> String {
        switch distance {
        case ..<0.04: "On target"
        case ..<0.12: "Very close"
        case ..<0.3: "Close"
        case ..<0.55: "Getting closer"
        default: "Far away"
        }
    }

    /// How full the proximity ring is: `1` on target, `0` at the far corner or
    /// beyond. Clamped here, for drawing only — never feed it back into guidance.
    public static func proximityFill(_ distance: Double) -> Double {
        guard distance.isFinite else { return 0 }
        return 1 - min(max(distance, 0), 1)
    }
}
