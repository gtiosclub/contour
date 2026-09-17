//
//  PlaceholderViews.swift
//  ContourUI — Experience / Accessibility & Launch
//
//  Scaffolding so ContourApp has something to present on day one. These render
//  a labelled placeholder and nothing else — no camera session, no preview
//  layer, no overlay maths. The App Flow lane replaces them wholesale.
//

import ContourCore
import SwiftUI

/// Placeholder for the camera experience.
///
/// Renders a static notice. Replace with the real viewfinder.
public struct ContourCameraView: View {

    public init() {}

    public var body: some View {
        ContourPlaceholder(
            title: "Camera experience",
            detail: "ContourUI — owned by Experience. Not implemented yet."
        )
    }
}

/// Placeholder for the target selection flow.
///
/// Lists the buttons in `map` as plain text so the wiring is visible end to end.
/// Replace with the real selection UI.
public struct TargetSelectionView: View {

    private let map: SurfaceMap

    public init(map: SurfaceMap) {
        self.map = map
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContourPlaceholder(
                title: "Target selection",
                detail: "ContourUI — owned by Experience. Not implemented yet."
            )

            ForEach(map.buttons) { button in
                Text(button.label ?? "Unlabelled control")
                    .font(.body.monospaced())
                    .accessibilityLabel(button.label ?? "Unlabelled control")
            }
        }
    }
}

/// Shared look for the not-yet-built screens.
struct ContourPlaceholder: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
