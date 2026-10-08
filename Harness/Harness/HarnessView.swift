//
//  HarnessView.swift
//  Harness
//
//  Sliders, a quality picker, a target picker, and four outcome buttons.
//  Sends synthetic guidance to a nearby iPhone without a camera or ARKit.
//
//  COORDINATES: y increases DOWNWARD, so dragging the y slider right moves the
//  fingertip toward the BOTTOM of the panel. The preview square below is drawn
//  the same way. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import ContourMocks
import SwiftUI
import HarnessConnectivity

struct HarnessView: View {

    @Environment(HarnessConnection.self) private var connection
    @Bindable var model: HarnessModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                connectionControls
                Divider()
                panelPreview
                fingertipControls
                qualityControl
                targetControl
                Divider()
                outcomeControls
                Divider()
                logView
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contour Harness").font(.largeTitle.bold())
            Text("Send synthetic guidance to a nearby iPhone. "
                 + "No camera or tracking required.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Connection Status") {
                    Label(connectionTitle, systemImage: connectionSymbol)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(connectionColor)
                }
                LabeledContent("iPhone") {
                    Text(connection.peer.peerName ?? "None connected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(connection.peer.peerName ?? "None connected")
                }
//                LabeledContent("Packets Sent") {
//                    Text(connection.peer.sentCount, format: .number)
//                        .monospacedDigit()
//                }
                Text("Includes periodic position updates while connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = connection.peer.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Start") {
                        connection.start()
                        model.emit()
                    }
                    .disabled(connection.peer.status != .stopped)
                    Button("Stop") { connection.stop() }
                        .disabled(connection.peer.status == .stopped)
                    Button("Reconnect") {
                        connection.reconnect()
                        model.emit()
                    }
                    .disabled(connection.peer.status == .stopped)
                }

                Text("Open Harness Receiver on the iPhone. Reconnection is automatic while running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("iPhone Connection").font(.headline)
        }
    }

    private var connectionTitle: String {
        switch connection.peer.status {
        case .stopped: "Stopped"
        case .searching: "Searching for iPhone"
        case .connecting: "Connecting"
        case .connected: "Connected"
        }
    }

    private var connectionSymbol: String {
        switch connection.peer.status {
        case .stopped: "pause.circle"
        case .searching: "magnifyingglass"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        }
    }

    private var connectionColor: Color {
        switch connection.peer.status {
        case .stopped: .secondary
        case .searching, .connecting: .orange
        case .connected: .green
        }
    }

    /// The panel drawn in its own convention: origin top-left, y downward.
    private var panelPreview: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .border(.secondary)

                ForEach(model.map.buttons) { button in
                    let isTarget = button.id == model.targetID
                    Rectangle()
                        .fill(isTarget ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))
                        .border(isTarget ? Color.accentColor : Color.secondary)
                        .frame(
                            width: button.bounds.width * size.width,
                            height: button.bounds.height * size.height
                        )
                        .overlay(
                            Text(button.label ?? "?")
                                .font(.caption2)
                                .minimumScaleFactor(0.5)
                                .padding(2)
                        )
                        .offset(
                            x: button.bounds.origin.x * size.width,
                            y: button.bounds.origin.y * size.height
                        )
                }

                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .offset(
                        x: model.fingertipX * size.width - 6,
                        y: model.fingertipY * size.height - 6
                    )
            }
        }
        .frame(height: 200)
        .accessibilityHidden(true)
        .help("Normalized panel space: (0,0) top-left, y increases downward.")
    }

    private var fingertipControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fingertip — normalized panel space").font(.headline)

            LabeledContent("x  \(model.fingertipX, format: .number.precision(.fractionLength(2)))") {
                Slider(value: $model.fingertipX, in: -0.25...1.25)
                    .accessibilityLabel("Fingertip x, zero is the left edge")
            }
            LabeledContent("y  \(model.fingertipY, format: .number.precision(.fractionLength(2)))") {
                Slider(value: $model.fingertipY, in: -0.25...1.25)
                    .accessibilityLabel("Fingertip y, zero is the top edge, larger is lower")
            }

            Text("Sliders run past 0…1 on purpose — off-panel positions are legal "
                 + "and guidance has to handle them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(model.isWalking ? "Stop walk" : "Walk to target") {
                model.toggleWalk()
            }
        }
    }

    private var qualityControl: some View {
        Picker("Tracking quality", selection: $model.trackingQuality) {
            ForEach(TrackingQuality.allCases, id: \.self) { quality in
                Text(quality.rawValue.capitalized).tag(quality)
            }
        }
        .pickerStyle(.segmented)
    }

    private var targetControl: some View {
        Picker("Target", selection: $model.targetID) {
            ForEach(model.map.buttons) { button in
                Text(button.label ?? "Unlabelled").tag(button.id)
            }
        }
    }

    private var outcomeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Outcome signals").font(.headline)
            Text("Fire one by hand, out of band from the sliders.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                ForEach(OutcomeSignal.allCases, id: \.self) { outcome in
                    Button(outcome.rawValue) { model.fire(outcome) }
                        .accessibilityLabel("Fire \(outcome.rawValue) signal")
                }
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sent to the feedback engine").font(.headline)

            if model.log.isEmpty {
                Text("Nothing yet. Move a slider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.log.prefix(12)) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.note)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(PrintingFeedbackEngine.describe(entry.state))
                            .font(.caption.monospaced())
                    }
                }
            }
        }
    }
}
