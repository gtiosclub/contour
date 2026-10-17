//
//  ViewfinderPlaceholder.swift
//  ContourUI — Experience / App Flow
//
//  What stands in for the camera when there is none: the Simulator, a denied
//  permission, a screenshot. A dark gradient, optionally a drawing of a sample
//  panel (so the Simulator demo still looks like pointing at a microwave), and
//  one line saying why there is no picture.
//

import ContourCore
import SwiftUI

/// A tasteful stand-in for the live camera preview.
public struct ViewfinderPlaceholder: View {

    private let sample: SurfaceMap?
    private let message: String
    private let highlightedID: UUID?
    private let fingertip: PanelPoint?

    /// - Parameters:
    ///   - sample: a panel to draw in the viewfinder, e.g. the mock microwave.
    ///   - message: why there is no camera — "Camera unavailable in Simulator".
    ///   - highlightedID: a control to mark, while guiding.
    ///   - fingertip: where to draw the finger, while guiding.
    public init(
        sample: SurfaceMap? = nil,
        message: String,
        highlightedID: UUID? = nil,
        fingertip: PanelPoint? = nil
    ) {
        self.sample = sample
        self.message = message
        self.highlightedID = highlightedID
        self.fingertip = fingertip
    }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: ContourTheme.Spacing.l) {
                if let sample {
                    PanelSketch(map: sample, showsControls: highlightedID != nil,
                                highlightedID: highlightedID, outlinesOnlyHighlighted: true,
                                fingertip: fingertip)
                        .padding(.horizontal, ContourTheme.Spacing.xl)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                }
                Label(message, systemImage: "video.slash")
                    .font(ContourTheme.Typography.caption)
                    .foregroundStyle(ContourTheme.Colors.textSecondary)
                    .padding(.horizontal, ContourTheme.Spacing.m)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, ContourTheme.Spacing.xs)
                    .background(ContourTheme.Colors.chrome.opacity(0.75), in: .capsule)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}
