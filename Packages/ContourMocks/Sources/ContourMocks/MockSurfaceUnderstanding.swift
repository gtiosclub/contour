//
//  MockSurfaceUnderstanding.swift
//  ContourMocks
//
//  Surface Understanding's stand-in. Returns the same microwave panel every time.
//
//  COORDINATES: normalized panel space, (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Canned `SurfaceMap`s for development, demos, and tests.
public enum MockSurfaceMaps {

    /// A six-button microwave keypad, two rows of three.
    ///
    /// ```
    ///        x=0                                  x=1
    ///   y=0   +----------------------------------+
    ///         |                                  |
    ///         |  [Popcorn ] [Beverage] [Defrost] |   <- y 0.18 ... 0.38
    ///         |                                  |
    ///         |  [Add 30s ] [ Start  ] [ Stop  ] |   <- y 0.52 ... 0.72
    ///         |                                  |
    ///   y=1   +----------------------------------+
    ///            0.06     0.38     0.70
    /// ```
    ///
    /// Confidences are deliberately uneven: "Defrost" is the scuffed one at
    /// `0.61`, so anything that filters on per-button confidence has something
    /// to filter. Panel confidence is `0.94`.
    ///
    /// Ids are hardcoded, so they are stable across runs and across machines —
    /// you can write an assertion against a specific button id.
    public static let microwave: SurfaceMap = {
        func id(_ suffix: String) -> UUID {
            UUID(uuidString: "C047C0DE-0000-4000-8000-0000000000\(suffix)")!
        }

        let columnX = [0.06, 0.38, 0.70]
        let width = 0.24
        let height = 0.20

        func button(
            _ suffix: String,
            _ label: String,
            column: Int,
            y: Double,
            confidence: Double
        ) -> SurfaceMap.Button {
            SurfaceMap.Button(
                id: id(suffix),
                label: label,
                bounds: PanelRect(
                    x: columnX[column],
                    y: y,
                    width: width,
                    height: height
                ),
                confidence: confidence
            )
        }

        return SurfaceMap(
            buttons: [
                button("01", "Popcorn", column: 0, y: 0.18, confidence: 0.93),
                button("02", "Beverage", column: 1, y: 0.18, confidence: 0.88),
                button("03", "Defrost", column: 2, y: 0.18, confidence: 0.61),
                button("04", "Add 30 Sec", column: 0, y: 0.52, confidence: 0.90),
                button("05", "Start", column: 1, y: 0.52, confidence: 0.97),
                button("06", "Stop/Clear", column: 2, y: 0.52, confidence: 0.95),
            ],
            confidence: 0.94
        )
    }()

    /// The "Start" button — the default target for demos and for
    /// `MockTrackingSource`.
    public static var microwaveStartButton: SurfaceMap.Button {
        // Force-unwrapped on purpose: if this stops resolving, the canned map
        // above was edited wrongly and every mock consumer should fail loudly.
        microwave.button(labelled: "Start")!
    }
}

/// A `SurfaceUnderstanding` that always returns the same canned microwave panel.
///
/// Deterministic: same input, same output, no randomness, no I/O. The `photo`
/// argument is ignored entirely — this mock never decodes anything.
public struct MockSurfaceUnderstanding: SurfaceUnderstanding {

    /// The map to return.
    public let map: SurfaceMap

    /// If set, `surfaceMap(from:)` throws this instead of returning `map`.
    /// Use it to exercise the failure paths without waiting for Surface Understanding.
    public let failure: SurfaceUnderstandingError?

    /// Artificial delay before returning, to stand in for detection latency.
    /// Fixed, not random.
    public let latency: Duration

    public init(
        map: SurfaceMap = MockSurfaceMaps.microwave,
        failure: SurfaceUnderstandingError? = nil,
        latency: Duration = .zero
    ) {
        self.map = map
        self.failure = failure
        self.latency = latency
    }

    public func surfaceMap(from photo: PanelPhoto) async throws -> SurfaceMap {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        if let failure {
            throw failure
        }
        return map
    }
}
