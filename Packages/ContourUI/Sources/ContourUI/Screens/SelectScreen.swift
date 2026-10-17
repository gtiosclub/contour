//
//  SelectScreen.swift
//  ContourUI — Experience / App Flow
//
//  Stage: selectingTarget. Two ways to choose, both one gesture:
//  - Say it. "Say a button" is the big primary action at the bottom, and the
//    Magic Tap (two-finger double-tap) starts it from anywhere.
//  - Pick it. The controls are listed in reading order, top row first, each
//    row saying its name, where it is ("top left"), and how sure detection is.
//    A "Controls" rotor jumps between them; an "Unsure controls" rotor finds
//    the ones that might be misread.
//  The photo above with the controls drawn on it is for sighted helpers; it is
//  hidden from VoiceOver because the list says the same thing in order.
//

import ContourCore
import SwiftUI

/// Choose which control to be guided to.
public struct SelectScreen: View {

    private let map: SurfaceMap
    private let layout: PanelLayout
    private let photo: PanelPhoto?
    private let quad: PanelQuad?
    private let canListen: Bool
    private let isListening: Bool
    private let heard: String?
    private let message: String?
    private let onChoose: (SurfaceMap.Button) -> Void
    private let onSay: () -> Void
    private let onRescan: () -> Void

    @Namespace private var rotor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - map: what Surface read.
    ///   - photo: the photo it read it from. The mock pipeline's empty photo
    ///     draws the panel from the map instead.
    ///   - quad: where the panel is in `photo`, so controls land on it.
    ///   - canListen: whether "Say a button" is available.
    ///   - isListening: a spoken request is being heard now.
    ///   - heard: what was heard last, to show.
    ///   - message: an error to show.
    public init(
        map: SurfaceMap,
        photo: PanelPhoto? = nil,
        quad: PanelQuad? = nil,
        canListen: Bool = true,
        isListening: Bool = false,
        heard: String? = nil,
        message: String? = nil,
        onChoose: @escaping (SurfaceMap.Button) -> Void,
        onSay: @escaping () -> Void,
        onRescan: @escaping () -> Void
    ) {
        self.map = map
        self.layout = PanelLayout(map: map)
        self.photo = photo
        self.quad = quad
        self.canListen = canListen
        self.isListening = isListening
        self.heard = heard
        self.message = message
        self.onChoose = onChoose
        self.onSay = onSay
        self.onRescan = onRescan
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ContourTheme.Spacing.l) {
                header
                picture
                if let message {
                    MessageBanner(text: message)
                } else if let heard {
                    MessageBanner(text: heard, systemImage: "waveform", tint: ContourTheme.Colors.info)
                }
                controls
            }
            .padding(.horizontal, ContourTheme.Spacing.m)
            .padding(.vertical, ContourTheme.Spacing.m)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .background(ContourTheme.Colors.surface.ignoresSafeArea())
        .foregroundStyle(ContourTheme.Colors.textPrimary)
        .contourMagicTap { if canListen && !isListening { onSay() } }
        .accessibilityRotor("Controls") {
            ForEach(layout.entries) { entry in
                AccessibilityRotorEntry(Text(layout.accessibilityLabel(for: entry)), id: entry.id, in: rotor)
            }
        }
        .accessibilityRotor("Unsure controls") {
            ForEach(layout.entries.filter { PanelLayout.isUnsure($0.button) }) { entry in
                AccessibilityRotorEntry(Text(layout.accessibilityLabel(for: entry)), id: entry.id, in: rotor)
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: ContourTheme.Spacing.xxs) {
            Text("Choose a button")
                .font(ContourTheme.Typography.title)
                .accessibilityAddTraits(.isHeader)
            Text(countLine)
                .font(ContourTheme.Typography.body)
                .foregroundStyle(ContourTheme.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var countLine: String {
        let count = map.buttons.count
        let unsure = map.buttons.filter(PanelLayout.isUnsure).count
        let found = count == 1 ? "1 control found" : "\(count) controls found"
        return unsure == 0 ? found : "\(found), \(unsure) unsure"
    }

    @ViewBuilder
    private var picture: some View {
        if !map.buttons.isEmpty {
            PanelPicture(photo: photo, quad: quad, map: map, onChoose: onChoose)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize
                       ? ContourTheme.Size.selectionPictureMaxHeight * 0.6
                       : ContourTheme.Size.selectionPictureMaxHeight)
                .clipShape(.rect(cornerRadius: ContourTheme.Radius.card))
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        LazyVStack(spacing: ContourTheme.Spacing.s) {
            ForEach(layout.entries) { entry in
                ControlRow(title: layout.title(for: entry), position: entry.position,
                           unsure: PanelLayout.isUnsure(entry.button)) {
                    onChoose(entry.button)
                }
                .accessibilityLabel(layout.accessibilityLabel(for: entry))
                .accessibilityValue(PanelLayout.confidenceWording(entry.button.confidence))
                .accessibilityHint("Double-tap to be guided to this button.")
                .accessibilityRotorEntry(id: entry.id, in: rotor)
            }
            if map.buttons.isEmpty {
                Text("No controls were found. Scan again, closer and straight on.")
                    .font(ContourTheme.Typography.body)
                    .foregroundStyle(ContourTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: ContourTheme.Spacing.s) {
            if canListen && !map.buttons.isEmpty {
                ContourActionButton(isListening ? "Listening…" : "Say a button",
                                    systemImage: isListening ? "waveform" : "mic.fill",
                                    hint: "Say the name of the button you want, like Start.",
                                    action: onSay)
                    .disabled(isListening)
            }
            ContourActionButton("Scan again", systemImage: "camera.viewfinder",
                                role: map.buttons.isEmpty ? .primary : .secondary,
                                hint: "Goes back to the camera to read the panel again.",
                                action: onRescan)
        }
        .padding(.horizontal, ContourTheme.Spacing.m)
        .padding(.top, ContourTheme.Spacing.s)
        .padding(.bottom, ContourTheme.Spacing.xs)
        .background {
            // Solid behind the buttons, with a short fade above so rows
            // scrolling underneath never show through the actions.
            ContourTheme.Colors.surface
                .overlay(alignment: .top) {
                    LinearGradient(colors: [ContourTheme.Colors.surface.opacity(0), ContourTheme.Colors.surface],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: ContourTheme.Spacing.l)
                        .offset(y: -ContourTheme.Spacing.l)
                }
                .ignoresSafeArea()
        }
    }
}

/// One control in the list: a big, plain row.
private struct ControlRow: View {
    let title: String
    let position: String
    let unsure: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ContourTheme.Spacing.m) {
                VStack(alignment: .leading, spacing: ContourTheme.Spacing.xxs) {
                    Text(title)
                        .font(ContourTheme.Typography.headline)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: ContourTheme.Spacing.xs) {
                        if !position.isEmpty {
                            Text(position.prefix(1).uppercased() + position.dropFirst())
                                .foregroundStyle(ContourTheme.Colors.textSecondary)
                        }
                        if unsure {
                            Label("Unsure", systemImage: "questionmark.circle.fill")
                                .foregroundStyle(ContourTheme.Colors.unsure)
                        }
                    }
                    .font(ContourTheme.Typography.caption)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(ContourTheme.Typography.headline)
                    .foregroundStyle(ContourTheme.Colors.textSecondary)
            }
            .foregroundStyle(ContourTheme.Colors.textPrimary)
            .padding(.horizontal, ContourTheme.Spacing.l)
            .padding(.vertical, ContourTheme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: ContourTheme.Size.rowMinHeight, alignment: .leading)
            .background(ContourTheme.Colors.surfaceRaised,
                        in: .rect(cornerRadius: ContourTheme.Radius.row))
            .overlay {
                if unsure {
                    RoundedRectangle(cornerRadius: ContourTheme.Radius.row)
                        .strokeBorder(ContourTheme.Colors.unsure,
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                }
            }
            .contentShape(.rect(cornerRadius: ContourTheme.Radius.row))
        }
        .buttonStyle(.plain)
    }
}
