//
//  MockKeypad.swift
//  ContourMocks — Experience / Mocks & Integration
//
//  The issue #12 six-button microwave: Start, Stop, Popcorn, +30s, Defrost and
//  an icon-only Cancel. This is an ADDITIONAL canned map, not a replacement for
//  `MockSurfaceMaps.microwave`: other teams' tests pin that map's labels,
//  confidences ("Defrost" at 0.61) and the fact that every button is labelled,
//  so it stays byte-for-byte as it was. Use `microwaveKeypad` when you want the
//  icon-only button or the `MockRun` presets.
//
//  COORDINATES: normalized panel space, (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

extension MockSurfaceMaps {

    /// The six controls on `microwaveKeypad`, with stable ids.
    ///
    /// Use these instead of `button(labelled:)` when you need the icon-only
    /// `cancel` button — it has no label to look up by.
    public enum KeypadButton: String, CaseIterable, Hashable, Sendable {
        case popcorn
        case defrost
        case addThirtySeconds
        case cancel
        case stop
        case start

        /// Hardcoded, so it is the same on every machine and every run.
        /// Disjoint from the ids in `microwave`.
        public var id: UUID {
            let suffix: String
            switch self {
            case .popcorn: suffix = "01"
            case .defrost: suffix = "02"
            case .addThirtySeconds: suffix = "03"
            case .cancel: suffix = "04"
            case .stop: suffix = "05"
            case .start: suffix = "06"
            }
            return UUID(uuidString: "C047C0DE-0000-4000-8000-0000000012\(suffix)")!
        }

        /// The printed label, or `nil` for the icon-only `cancel` (an ✕ glyph).
        public var label: String? {
            switch self {
            case .popcorn: "Popcorn"
            case .defrost: "Defrost"
            case .addThirtySeconds: "+30s"
            case .cancel: nil
            case .stop: "Stop"
            case .start: "Start"
            }
        }

        /// A name for humans (debug UI, VoiceOver), including for `cancel`.
        public var displayName: String {
            label ?? "Cancel (icon only)"
        }

        /// Per-button detector confidence. Uneven on purpose: `popcorn` is the
        /// scuffed one at `0.72`.
        public var confidence: Double {
            switch self {
            case .popcorn: 0.72
            case .defrost: 0.83
            case .addThirtySeconds: 0.88
            case .cancel: 0.80
            case .stop: 0.91
            case .start: 0.94
            }
        }

        /// Grid position: `(column, row)`, row 0 on top.
        var cell: (column: Int, row: Int) {
            switch self {
            case .popcorn: (0, 0)
            case .defrost: (1, 0)
            case .addThirtySeconds: (2, 0)
            case .cancel: (0, 1)
            case .stop: (1, 1)
            case .start: (2, 1)
            }
        }
    }

    /// The issue #12 microwave keypad: two rows of three, one icon-only button.
    ///
    /// ```
    ///        x=0                                  x=1
    ///   y=0   +----------------------------------+
    ///         |                                  |
    ///         |  [Popcorn] [Defrost] [  +30s  ]  |   <- y 0.20 ... 0.40
    ///         |                                  |
    ///         |  [   ✕   ] [ Stop  ] [ Start  ]  |   <- y 0.55 ... 0.75
    ///         |                                  |
    ///   y=1   +----------------------------------+
    ///           0.08      0.39      0.70   (width 0.22)
    /// ```
    ///
    /// Confidences: Start 0.94, Stop 0.91, +30s 0.88, Defrost 0.83,
    /// Cancel 0.80, Popcorn 0.72. Panel confidence 0.93. Cancel's label is
    /// `nil` — it is printed as an ✕ icon, which OCR cannot read.
    public static let microwaveKeypad: SurfaceMap = {
        let columnX = [0.08, 0.39, 0.70]
        let rowY = [0.20, 0.55]
        return SurfaceMap(
            buttons: KeypadButton.allCases.map { key in
                SurfaceMap.Button(
                    id: key.id,
                    label: key.label,
                    bounds: PanelRect(
                        x: columnX[key.cell.column],
                        y: rowY[key.cell.row],
                        width: 0.22,
                        height: 0.20
                    ),
                    confidence: key.confidence
                )
            },
            confidence: 0.93
        )
    }()

    /// One button of `microwaveKeypad`.
    public static func keypadButton(_ key: KeypadButton) -> SurfaceMap.Button {
        // Force-unwrapped on purpose: every case is in the map by construction.
        microwaveKeypad.buttons.first { $0.id == key.id }!
    }
}
