//
//  OutcomeScreen.swift
//  ContourUI — Experience / App Flow
//
//  Stage: finished. One full-screen result per OutcomeSignal, and the next
//  steps as big buttons, most likely first. notFound and lowConfidence look
//  (and read) different on purpose: one means "that control isn't here", the
//  other "try again, better".
//

import ContourCore
import SwiftUI

/// What an outcome says on screen.
public struct OutcomeContent: Hashable, Sendable {
    public let symbol: String
    public let title: String
    public let message: String

    /// - Parameters:
    ///   - targetName: the control guided to, if any.
    ///   - detail: replaces the default message, e.g. what was heard.
    public init(outcome: OutcomeSignal, targetName: String? = nil, detail: String? = nil) {
        let message: String
        switch outcome {
        case .arrived:
            symbol = "checkmark.circle.fill"
            title = targetName.map { "You're on \($0)" } ?? "You're on it"
            message = "Press the button now."
        case .lostTracking:
            symbol = "viewfinder"
            title = "Lost sight of the panel"
            message = "Point the phone back at the panel, then guide again."
        case .notFound:
            symbol = "questionmark.circle.fill"
            title = "Not on this panel"
            message = "That button isn't on this panel. Choose another, or scan again."
        case .lowConfidence:
            symbol = "exclamationmark.triangle.fill"
            title = "Couldn't read it clearly"
            message = "Add some light and hold the phone steady, then scan again."
        }
        self.message = detail ?? message
    }
}

/// How an interaction ended, and what to do next.
public struct OutcomeScreen: View {

    private let outcome: OutcomeSignal
    private let content: OutcomeContent
    private let onGuideAgain: (() -> Void)?
    private let onChooseAnother: (() -> Void)?
    private let onScanNew: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = ContourTheme.Size.outcomeSymbol

    /// Actions that are `nil` are not offered — e.g. no "Guide again" when
    /// there was never a target.
    public init(
        outcome: OutcomeSignal,
        targetName: String? = nil,
        detail: String? = nil,
        onGuideAgain: (() -> Void)?,
        onChooseAnother: (() -> Void)?,
        onScanNew: @escaping () -> Void
    ) {
        self.outcome = outcome
        self.content = OutcomeContent(outcome: outcome, targetName: targetName, detail: detail)
        self.onGuideAgain = onGuideAgain
        self.onChooseAnother = onChooseAnother
        self.onScanNew = onScanNew
    }

    public var body: some View {
        let tint = ContourTheme.Colors.tint(for: outcome)
        ScrollView {
            VStack(spacing: ContourTheme.Spacing.l) {
                Spacer(minLength: ContourTheme.Spacing.xl)
                Image(systemName: content.symbol)
                    .font(.system(size: min(symbolSize, 160), weight: .bold))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(spacing: ContourTheme.Spacing.s) {
                    Text(content.title)
                        .font(ContourTheme.Typography.display)
                        .accessibilityAddTraits(.isHeader)
                    Text(content.message)
                        .font(ContourTheme.Typography.body)
                        .foregroundStyle(ContourTheme.Colors.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ContourTheme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .foregroundStyle(ContourTheme.Colors.textPrimary)
        .background {
            ZStack {
                ContourTheme.Colors.surface
                RadialGradient(colors: [tint.opacity(0.35), .clear], center: .top,
                               startRadius: 0, endRadius: 520)
            }
            .ignoresSafeArea()
        }
    }

    private var actions: some View {
        VStack(spacing: ContourTheme.Spacing.s) {
            ForEach(Array(orderedActions.enumerated()), id: \.offset) { index, action in
                ContourActionButton(action.title, systemImage: action.symbol,
                                    role: index == 0 ? .primary : .secondary,
                                    hint: action.hint, action: action.run)
            }
        }
        .padding(.horizontal, ContourTheme.Spacing.m)
        .padding(.bottom, ContourTheme.Spacing.xs)
    }

    private struct Action {
        let title: String
        let symbol: String
        let hint: String
        let run: () -> Void
    }

    /// The most likely next step first; it becomes the primary button.
    private var orderedActions: [Action] {
        let guide = onGuideAgain.map {
            Action(title: "Guide again", symbol: "arrow.clockwise",
                   hint: "Guides you to the same button again.", run: $0)
        }
        let choose = onChooseAnother.map {
            Action(title: outcome == .notFound ? "Choose a button" : "Choose another button",
                   symbol: "list.bullet", hint: "Goes back to the controls on this panel.", run: $0)
        }
        let scan = Action(title: "Scan a new panel", symbol: "camera.viewfinder",
                          hint: "Goes back to the camera.", run: onScanNew)
        let order: [Action?] = switch outcome {
        case .arrived: [choose, guide, scan]
        case .lostTracking: [guide, scan, choose]
        case .notFound: [choose, scan]
        case .lowConfidence: [scan, guide]
        }
        return order.compactMap { $0 }
    }
}

#Preview("Arrived") {
    OutcomeScreen(outcome: .arrived, targetName: "Start", onGuideAgain: {}, onChooseAnother: {}, onScanNew: {})
}
