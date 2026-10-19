//
//  DetectingScreen.swift
//  ContourUI — Experience / App Flow
//
//  Stage: detecting. The photo just taken, frozen and dimmed, so the user (or
//  whoever is helping) sees exactly what is being read; a progress indicator;
//  and Cancel, which goes back to aiming.
//

import ContourCore
import SwiftUI

/// The panel is being read.
public struct DetectingScreen<Background: View>: View {

    private let photo: PanelPhoto?
    private let sample: SurfaceMap?
    private let background: Background
    private let onCancel: () -> Void

    /// - Parameters:
    ///   - photo: the still being read. Until it arrives (or if it is the mock
    ///     pipeline's empty photo), `sample` is drawn, else `background`.
    ///   - sample: a panel to draw when there is no photo to freeze.
    ///   - onCancel: go back to aiming.
    ///   - background: shown when there is neither photo nor sample. Not a
    ///     second camera preview: this screen fades in over the aiming screen's,
    ///     and two preview layers on one session blank the screen on a phone.
    public init(
        photo: PanelPhoto?,
        sample: SurfaceMap? = nil,
        onCancel: @escaping () -> Void,
        @ViewBuilder background: () -> Background
    ) {
        self.photo = photo
        self.sample = sample
        self.background = background()
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            ContourTheme.Colors.chrome.ignoresSafeArea()
            ZStack {
                background.ignoresSafeArea()
                if photo != nil || sample != nil {
                    ContourTheme.Colors.chrome.ignoresSafeArea()
                    PanelPicture(photo: photo, map: sample, showsControls: false)
                        .padding(photo?.data.isEmpty == false ? 0 : ContourTheme.Spacing.xl)
                }
            }
            .accessibilityHidden(true)
            ContourTheme.Colors.scrim.ignoresSafeArea()

            VStack(spacing: ContourTheme.Spacing.l) {
                Spacer()
                VStack(spacing: ContourTheme.Spacing.m) {
                    ProgressView()
                        .controlSize(.extraLarge)
                        .tint(ContourTheme.Colors.textPrimary)
                    Text("Reading the panel…")
                        .font(ContourTheme.Typography.title)
                        .accessibilityAddTraits(.isHeader)
                    Text("Hold still.")
                        .font(ContourTheme.Typography.body)
                        .foregroundStyle(ContourTheme.Colors.textSecondary)
                }
                .foregroundStyle(ContourTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(ContourTheme.Spacing.xl)
                .contourGlass()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Reading the panel. Hold still.")
                Spacer()
                ContourActionButton("Cancel", systemImage: "xmark", role: .secondary,
                                    hint: "Stops reading and goes back to aiming the camera.",
                                    action: onCancel)
            }
            .padding(.horizontal, ContourTheme.Spacing.m)
            .padding(.bottom, ContourTheme.Spacing.m)
        }
        .accessibilityAction(.escape, onCancel)
    }
}

#Preview("Detecting") {
    DetectingScreen(photo: nil, onCancel: {}) {
        ViewfinderPlaceholder(message: "Camera unavailable in Simulator")
    }
}
