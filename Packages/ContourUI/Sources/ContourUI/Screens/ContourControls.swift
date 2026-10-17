//
//  ContourControls.swift
//  ContourUI — Experience / Accessibility & Launch
//
//  The few building blocks every screen shares: big glass actions, the glass
//  instruction card, a message banner, and the viewfinder's corner marks.
//  Values come from ContourTheme.
//

import SwiftUI

// MARK: - Glass

extension View {

    /// Liquid Glass in `shape`, tinted, or a solid fill when the user has
    /// turned on Increase Contrast — glass over a moving camera image is the
    /// first thing to lose legibility.
    func contourGlass(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: some Shape = .rect(cornerRadius: ContourTheme.Radius.card)
    ) -> some View {
        modifier(ContourGlass(tint: tint, interactive: interactive, shape: shape))
    }
}

private struct ContourGlass<S: Shape>: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if contrast == .increased {
            content
                .background(tint ?? ContourTheme.Colors.surfaceRaised, in: shape)
                .overlay(shape.stroke(ContourTheme.Colors.textPrimary, lineWidth: 2))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return glass.interactive(interactive)
    }
}

// MARK: - Actions

/// A large, full-width action for the bottom of a screen.
public struct ContourActionButton: View {

    /// How loud the action is.
    public enum Role: Sendable {
        /// The one thing to do next. Accent-tinted.
        case primary
        /// An alternative. Clear glass.
        case secondary
        /// Stop. Red.
        case destructive
    }

    let title: String
    let systemImage: String?
    let role: Role
    let height: CGFloat
    let hint: String?
    let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        role: Role = .primary,
        height: CGFloat = ContourTheme.Size.actionHeight,
        hint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.height = height
        self.hint = hint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: ContourTheme.Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(ContourTheme.Typography.action)
            .foregroundStyle(foreground)
            .padding(.horizontal, ContourTheme.Spacing.l)
            .padding(.vertical, ContourTheme.Spacing.s)
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(.rect(cornerRadius: ContourTheme.Radius.action))
            .contourGlass(tint: tint, interactive: true,
                          in: .rect(cornerRadius: ContourTheme.Radius.action))
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint ?? "")
    }

    private var tint: Color? {
        switch role {
        case .primary: ContourTheme.Colors.accent
        case .secondary: nil
        case .destructive: ContourTheme.Colors.danger
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: ContourTheme.Colors.onAccent
        case .secondary, .destructive: ContourTheme.Colors.textPrimary
        }
    }
}

// MARK: - Cards

/// A glass card with an instruction, floating over the camera.
struct InstructionCard: View {
    let title: String
    var detail: String?
    var systemImage: String?

    var body: some View {
        VStack(spacing: ContourTheme.Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(ContourTheme.Typography.headline)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(ContourTheme.Typography.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(ContourTheme.Typography.caption)
                    .foregroundStyle(ContourTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(ContourTheme.Colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, ContourTheme.Spacing.l)
        .padding(.vertical, ContourTheme.Spacing.m)
        .frame(maxWidth: 560)
        .contourGlass()
        .accessibilityElement(children: .combine)
    }
}

/// A short message: an error, or what was heard.
struct MessageBanner: View {
    let text: String
    var systemImage = "exclamationmark.circle.fill"
    var tint = ContourTheme.Colors.warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ContourTheme.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(ContourTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(ContourTheme.Typography.body)
        .padding(ContourTheme.Spacing.m)
        .frame(maxWidth: 560)
        .contourGlass()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Viewfinder

/// Four corner marks framing where the panel should go. Decorative.
struct CornerGuides: View {
    var body: some View {
        GeometryReader { geometry in
            let length = ContourTheme.Size.cornerGuideLength
            let rect = CGRect(origin: .zero, size: geometry.size)
            Path { path in
                // Top-left, top-right, bottom-right, bottom-left.
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
                path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
                path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
            }
            .stroke(ContourTheme.Colors.cornerGuide,
                    style: StrokeStyle(lineWidth: ContourTheme.Size.cornerGuideLine,
                                       lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Darkens the top and bottom of the camera so glass and text stay legible.
struct CameraScrim: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(maxHeight: 220)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(maxHeight: 320)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - VoiceOver

extension View {

    /// The Magic Tap — VoiceOver's two-finger double-tap — runs `action` from
    /// anywhere on the screen: the screen's one most important thing. iOS only.
    func contourMagicTap(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
        accessibilityAction(.magicTap, action)
        #else
        self
        #endif
    }
}
