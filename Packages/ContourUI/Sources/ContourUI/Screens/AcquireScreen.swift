//
//  AcquireScreen.swift
//  ContourUI — Experience / App Flow
//
//  Stage: acquiringPanel. Full-bleed camera, one instruction at the top, and
//  the whole bottom third of the screen is the shutter — a user who cannot see
//  the screen can hit it with a thumb anywhere down there. VoiceOver users can
//  also two-finger double-tap (the Magic Tap) from anywhere to scan.
//
//  The camera preview is passed in: the camera belongs to ContourApp.
//

import ContourCore
import SwiftUI

/// Point the phone at the panel and take the shot.
public struct AcquireScreen<Preview: View>: View {

    private let preview: Preview
    private let message: String?
    private let isCapturing: Bool
    private let onScan: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var shutterSize = ContourTheme.Size.shutter

    /// - Parameters:
    ///   - message: an error or hint to show (and that the app also speaks),
    ///     e.g. "Surface did not return a trackable panel outline…".
    ///   - isCapturing: the shot is being taken; the shutter shows progress.
    ///   - onScan: the user pressed the shutter.
    ///   - preview: the live camera, or a placeholder when there is none.
    public init(
        message: String? = nil,
        isCapturing: Bool = false,
        onScan: @escaping () -> Void,
        @ViewBuilder preview: () -> Preview
    ) {
        self.preview = preview()
        self.message = message
        self.isCapturing = isCapturing
        self.onScan = onScan
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                ContourTheme.Colors.chrome.ignoresSafeArea()
                preview
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                CameraScrim()

                VStack(spacing: ContourTheme.Spacing.m) {
                    InstructionCard(title: "Point your phone at the panel",
                                    detail: "Hold it about a foot away, straight on.")
                    if let message {
                        MessageBanner(text: message)
                    }
                    CornerGuides()
                        .padding(.horizontal, ContourTheme.Spacing.l)
                        .padding(.vertical, ContourTheme.Spacing.m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    shutter
                        .frame(height: max(geometry.size.height / 3, shutterSize + 120))
                }
                .padding(.horizontal, ContourTheme.Spacing.m)
                .padding(.top, ContourTheme.Spacing.s)
            }
        }
        .contourMagicTap { if !isCapturing { onScan() } }
    }

    /// The bottom third: one enormous button with a shutter disc in it.
    private var shutter: some View {
        Button(action: onScan) {
            VStack(spacing: ContourTheme.Spacing.m) {
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .strokeBorder(ContourTheme.Colors.textPrimary, lineWidth: ContourTheme.Size.shutterRing)
                    Circle()
                        .fill(ContourTheme.Colors.accent)
                        .padding(ContourTheme.Size.shutterRing * 2)
                    if isCapturing {
                        ProgressView()
                            .controlSize(.large)
                            .tint(ContourTheme.Colors.onAccent)
                    } else {
                        Image(systemName: "viewfinder")
                            .font(.system(size: shutterSize * 0.38, weight: .bold))
                            .foregroundStyle(ContourTheme.Colors.onAccent)
                    }
                }
                .frame(width: shutterSize, height: shutterSize)
                Text(isCapturing ? "Scanning…" : "Scan panel")
                    .font(ContourTheme.Typography.action)
                    .foregroundStyle(ContourTheme.Colors.textPrimary)
                Spacer(minLength: ContourTheme.Spacing.m)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isCapturing)
        .accessibilityLabel(isCapturing ? "Scanning" : "Scan panel")
        .accessibilityHint("Takes a photo of the panel and reads its buttons. The whole bottom of the screen is this button.")
    }
}

#Preview("Acquire") {
    AcquireScreen(onScan: {}) {
        ViewfinderPlaceholder(message: "Camera unavailable in Simulator")
    }
}
