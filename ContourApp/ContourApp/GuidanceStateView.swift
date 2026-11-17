//
//  GuidanceStateView.swift
//  ContourApp
//
//  The guidance card for one phase of a session (#151). Words and actions
//  come from `GuidanceScreenContent`; this file only decides how they look.
//  The card sits over the bottom of the camera preview so the camera stays
//  visible behind the header.
//

import ContourUI
import SwiftUI

struct GuidanceStateView: View {
    let phase: GuidancePhase
    let targetLabel: String?
    /// What the feedback engine is currently saying.
    let instruction: String
    let perform: (GuidanceAction) -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Past this, single words such as "Guidance" no longer fit a phone's width.
    private static let maximumTitleSize: CGFloat = 64

    private var content: GuidanceScreenContent {
        GuidanceScreenContent(phase: phase, targetLabel: targetLabel)
    }

    /// While guiding, the screen shows what the user hears.
    private var message: String {
        let spoken = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return phase == .guiding && !spoken.isEmpty ? spoken : content.message
    }

    var body: some View {
        let style = PhaseStyle(phase)
        // Scroll only when the content cannot fit, e.g. at accessibility sizes.
        ViewThatFits(in: .vertical) {
            card(style)
            ScrollView { card(style) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            RoundedRectangle(cornerRadius: 32)
                .fill(.black.opacity(0.88))
            // Each phase gets its own edge color so it reads at a glance.
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(style.accent, lineWidth: 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
    }

    private func card(_ style: PhaseStyle) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // At accessibility sizes the symbol sits above the title so long
            // words are not broken to fit beside it.
            let heading = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            heading {
                Image(systemName: style.symbol)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(style.accent)
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.system(size: min(titleSize, Self.maximumTitleSize), weight: .heavy))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(message)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(Array(content.actions.enumerated()), id: \.element) { index, action in
                    Button(action.title) { perform(action) }
                        .buttonStyle(GuidanceActionStyle(prominent: index == 0, accent: style.accent))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

/// Shows `phase` on the guidance card, but holds the card steady through the
/// brief gaps live tracking produces many times a second. The pipeline's
/// phase stays exact; only what is drawn waits for a change to last.
struct SettledGuidanceStateView: View {
    let phase: GuidancePhase
    let targetLabel: String?
    let instruction: String
    let perform: (GuidanceAction) -> Void

    @State private var shown: GuidancePhase?
    @State private var shownInstruction = ""

    /// How long `new` must last before it replaces `old` on screen, or `nil`
    /// to show it at once. Only soft changes wait: a short gap, or a finger
    /// slipping off the edge of the target. Outcomes always show immediately.
    static func settleDelay(from old: GuidancePhase, to new: GuidancePhase) -> Duration? {
        switch (old, new) {
        case (.guiding, .searching), (.holding, .searching),
             (.guiding, .findingFinger), (.holding, .findingFinger): .milliseconds(600)
        case (.holding, .guiding): .milliseconds(400)
        default: nil
        }
    }

    var body: some View {
        let current = shown ?? phase
        GuidanceStateView(phase: current, targetLabel: targetLabel,
                          instruction: shownInstruction.isEmpty ? instruction : shownInstruction,
                          perform: perform)
            .task(id: phase) {
                if let shown, let delay = Self.settleDelay(from: shown, to: phase) {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                }
                shown = phase
            }
            // Keep the last direction while a gap is being held, instead of
            // "Guidance paused." flashing in for a frame.
            .onChange(of: instruction, initial: true) {
                if phase == .guiding { shownInstruction = instruction }
            }
    }
}

/// Color and symbol for each phase. Accents are bright on black.
private struct PhaseStyle {
    let accent: Color
    let symbol: String

    init(_ phase: GuidancePhase) {
        switch phase {
        case .guiding:
            accent = Color(red: 0.35, green: 0.75, blue: 1)
            symbol = "hand.point.up.left.fill"
        case .searching:
            accent = Color(white: 0.75)
            symbol = "viewfinder"
        case .findingFinger:
            accent = Color(red: 0.8, green: 0.6, blue: 1)
            symbol = "hand.raised.slash.fill"
        case .holding:
            accent = .yellow
            symbol = "hand.raised.fill"
        case .arrived:
            accent = .green
            symbol = "checkmark.circle.fill"
        case .lostTracking:
            accent = .orange
            symbol = "eye.slash.fill"
        case .notFound, .lowConfidence, .cannotStart:
            accent = Color(red: 1, green: 0.4, blue: 0.4)
            symbol = "exclamationmark.triangle.fill"
        case .stopped:
            accent = Color(white: 0.75)
            symbol = "stop.circle.fill"
        }
    }
}

/// Full-width, at least 52 pt tall. The first action is filled in the
/// phase accent; the rest are outlined in white.
private struct GuidanceActionStyle: ButtonStyle {
    let prominent: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(prominent ? .black : .white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(prominent ? accent : .black)
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(prominent ? accent : .white, lineWidth: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#Preview("Guiding") {
    ZStack(alignment: .bottom) {
        Color.gray
        GuidanceStateView(phase: .guiding, targetLabel: "Start",
                          instruction: "Move up and to the left.", perform: { _ in })
            .padding(8)
    }
}

#Preview("Cannot start, AX5") {
    ZStack(alignment: .bottom) {
        Color.gray
        GuidanceStateView(phase: .cannotStart("Tracking could not read the reference photo. Capture a new reference."),
                          targetLabel: "Start", instruction: "", perform: { _ in })
            .padding(8)
    }
    .dynamicTypeSize(.accessibility5)
}

#Preview("Finding finger") {
    ZStack(alignment: .bottom) {
        Color.gray
        GuidanceStateView(phase: .findingFinger, targetLabel: "Start",
                          instruction: "Guidance paused.", perform: { _ in })
            .padding(8)
    }
}

#Preview("All phases") {
    let phases: [GuidancePhase] = [.guiding, .holding, .findingFinger, .searching, .lostTracking,
                                   .arrived, .notFound, .lowConfidence, .cannotStart("The panel corners are invalid."), .stopped]
    ScrollView {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .bottom), GridItem(.flexible(), alignment: .bottom)],
                  spacing: 8) {
            ForEach(phases, id: \.self) { phase in
                GuidanceStateView(phase: phase, targetLabel: "Start",
                                  instruction: "Move up and to the left.", perform: { _ in })
            }
        }
        .padding(8)
    }
    .background(Color.gray)
    .dynamicTypeSize(.xSmall)
}
