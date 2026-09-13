//
//  HarnessView.swift
//  Harness
//
//  Sliders, a quality picker, a target picker, and four outcome buttons.
//  That is the whole rig. No camera, no phone, no ARKit.
//
//  COORDINATES: y increases DOWNWARD, so dragging the y slider right moves the
//  fingertip toward the BOTTOM of the panel. The preview square below is drawn
//  the same way. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import ContourMocks
import SwiftUI

struct HarnessView: View {

    @Bindable var model: HarnessModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
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
            Text("Synthetic TrackingFrames for feedback development. "
                 + "No iPhone, no camera, no tracking.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
