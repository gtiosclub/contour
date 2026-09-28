import ContourCore
import Foundation

/// Canned surface maps for development, demos, and tests.
public enum MockSurfaceMap {
    /// A realistic six-button microwave keypad in normalized panel space.
    /// The cancel control is icon-only, so its label is intentionally nil.
    public static let microwave: SurfaceMap = {
        func id(_ suffix: String) -> UUID {
            UUID(uuidString: "C047C0DE-0000-4000-8000-0000000000\(suffix)")!
        }

        let columnX = [0.08, 0.39, 0.70]
        let rowY = [0.24, 0.53]

        func button(
            _ suffix: String,
            label: String?,
            column: Int,
            row: Int,
            confidence: Double
        ) -> SurfaceMap.Button {
            SurfaceMap.Button(
                id: id(suffix),
                label: label,
                bounds: PanelRect(x: columnX[column], y: rowY[row], width: 0.22, height: 0.18),
                confidence: confidence
            )
        }

        return SurfaceMap(
            buttons: [
                button("01", label: "Popcorn", column: 0, row: 0, confidence: 0.72),
                button("02", label: "Defrost", column: 1, row: 0, confidence: 0.80),
                button("03", label: "Stop", column: 2, row: 0, confidence: 0.91),
                button("04", label: "+30s", column: 0, row: 1, confidence: 0.88),
                button("05", label: "Start", column: 1, row: 1, confidence: 0.94),
                button("06", label: nil, column: 2, row: 1, confidence: 0.95)
            ],
            confidence: 0.94
        )
    }()

    public static var microwaveStartButton: SurfaceMap.Button {
        microwave.button(labelled: "Start")!
    }
}

/// Backward-compatible plural spelling used by existing clients.
public typealias MockSurfaceMaps = MockSurfaceMap

/// A SurfaceUnderstanding that always returns the same canned microwave panel.
public struct MockSurfaceUnderstanding: SurfaceUnderstanding {
    public let map: SurfaceMap
    public let quad: PanelQuad
    public let failure: SurfaceUnderstandingError?
    public let latency: Duration

    public init(
        map: SurfaceMap = MockSurfaceMap.microwave,
        quad: PanelQuad = .fullFrame,
        failure: SurfaceUnderstandingError? = nil,
        latency: Duration = .zero
    ) {
        self.map = map
        self.quad = quad
        self.failure = failure
        self.latency = latency
    }

    public func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        if let failure {
            throw failure
        }
        return PanelDetection(referencePhotoID: photo.id, quad: quad, map: map)
    }
}
