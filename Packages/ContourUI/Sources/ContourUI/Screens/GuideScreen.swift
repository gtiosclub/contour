//
//  GuideScreen.swift
//  ContourUI — Experience / App Flow
//
//  Stage: guiding. Haptics and audio do the guiding; this screen is for the
//  sighted helper and the low-vision user: the target's name, big; a ring that
//  fills as the finger closes in; an arrow pointing where to move; and the
//  largest Stop button in the app. Magic Tap stops too.
//
//  WHEN TRACKING CAN'T START
//  If tracking can't lock onto the panel at all, waiting won't help, so the
//  screen says why in `problem` and Stop becomes Scan again (Magic Tap too).
//
//  COORDINATES
//  GuidanceVector.direction is panel space, +dy DOWN — the same way up as the
//  screen, so the arrow rotates by the vector's angle as-is: (0, 1) points the
//  arrow down. Don't flip it. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import SwiftUI

/// Live guidance toward one control.
public struct GuideScreen<Background: View>: View {

    private let targetName: String
    private let guidance: GuidanceState?
    private let problem: String?
    private let background: Background
    private let onStop: () -> Void
    private let onRescan: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = ContourTheme.Size.heroText
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize = ContourTheme.Size.proximityRing

    /// - Parameters:
    ///   - target: where the finger is going.
    ///   - targetName: what to call it; defaults to its label or position.
    ///   - guidance: the latest state from the pipeline. `nil` until the first.
    ///   - problem: why guidance can't go on, said in place of the guidance
    ///     line. `nil` while guiding normally.
    ///   - onStop: stop guiding.
    ///   - onRescan: scan the panel again; offered instead of Stop while there
    ///     is a `problem`.
    ///   - background: the live camera, or a placeholder.
    public init(
        target: SurfaceMap.Button,
        targetName: String? = nil,
        guidance: GuidanceState?,
        problem: String? = nil,
        onStop: @escaping () -> Void,
        onRescan: (() -> Void)? = nil,
        @ViewBuilder background: () -> Background
    ) {
        self.targetName = targetName ?? PanelLayout.spokenName(for: target)
        self.guidance = guidance
        self.problem = problem
        self.background = background()
        self.onStop = onStop
        self.onRescan = onRescan
    }

    public var body: some View {
        let status = GuideStatus(guidance, problem: problem)
        let rescan = status.phase == .cannotTrack ? onRescan : nil
        ZStack {
            ContourTheme.Colors.chrome.ignoresSafeArea()
            background
                .ignoresSafeArea()
                .accessibilityHidden(true)
            CameraScrim()

            VStack(spacing: ContourTheme.Spacing.l) {
                VStack(spacing: ContourTheme.Spacing.xxs) {
                    Text("Guiding to")
                        .font(ContourTheme.Typography.caption)
                        .foregroundStyle(ContourTheme.Colors.textSecondary)
                    Text(targetName)
                        .font(.system(size: heroSize, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(ContourTheme.Colors.textPrimary)
                .padding(.horizontal, ContourTheme.Spacing.l)
                .padding(.vertical, ContourTheme.Spacing.m)
                .frame(maxWidth: .infinity)
                .contourGlass()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                // The ring sits low, above Stop, so the middle of the camera —
                // where the panel and the finger are — stays visible.
                Spacer(minLength: 0)

                ProximityRing(status: status, size: min(ringSize, 320), reduceMotion: reduceMotion)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Distance to \(targetName)")
                    .accessibilityValue(status.spoken)
                    .accessibilityAddTraits(.updatesFrequently)

                Text(status.line)
                    .font(ContourTheme.Typography.headline)
                    .foregroundStyle(ContourTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ContourTheme.Spacing.m)
                    .padding(.vertical, ContourTheme.Spacing.s)
                    .contourGlass(in: .capsule)
                    .accessibilityHidden(true)   // the ring's value says the same

                if let rescan {
                    ContourActionButton("Scan again", systemImage: "camera.viewfinder",
                                        height: ContourTheme.Size.stopHeight,
                                        hint: "Goes back to the camera to scan the panel again.",
                                        action: rescan)
                } else {
                    ContourActionButton("Stop", systemImage: "stop.fill", role: .destructive,
                                        height: ContourTheme.Size.stopHeight,
                                        hint: "Stops guiding. You can choose another button.",
                                        action: onStop)
                }
            }
            .padding(.horizontal, ContourTheme.Spacing.m)
            .padding(.vertical, ContourTheme.Spacing.m)
        }
        .contourMagicTap(rescan ?? onStop)
        .accessibilityAction(.escape, onStop)
    }
}

/// What the latest guidance state means for the screen.
struct GuideStatus: Equatable {

    enum Phase: Equatable { case starting, noFinger, moving, onTarget, lost, unclear, cannotTrack }

    let phase: Phase
    /// Ring fill, 0...1.
    let fill: Double
    /// Arrow angle in radians, clockwise from right (y is down).
    let angle: Double?

    /// - Parameter problem: why tracking can't start at all. Wins over `state`.
    init(_ state: GuidanceState?, problem: String? = nil) {
        if let problem {
            phase = .cannotTrack; fill = 0; angle = nil; problemWords = problem; return
        }
        guard let state else {
            phase = .starting; fill = 0; angle = nil; return
        }
        switch state.outcome {
        case .arrived?:
            phase = .onTarget; fill = 1; angle = nil
        case .lostTracking?:
            phase = .lost; fill = 0; angle = nil
        case .lowConfidence?:
            phase = .unclear; fill = 0; angle = nil
        case .notFound?, nil:
            if let vector = state.vector {
                let onTarget = vector.direction.magnitude == 0
                phase = onTarget ? .onTarget : .moving
                fill = GuidanceWording.proximityFill(vector.normalizedDistance)
                angle = onTarget ? nil : vector.direction.angle
                distanceWords = GuidanceWording.closeness(vector.normalizedDistance)
                directionWords = GuidanceWording.direction(vector.direction)
                return
            }
            phase = .noFinger; fill = 0; angle = nil
        }
    }

    private var distanceWords = ""
    private var directionWords = ""
    private var problemWords = ""

    /// The line under the ring.
    var line: String {
        switch phase {
        case .starting: "Starting guidance…"
        case .noFinger: "Put your finger on the panel"
        case .moving: "\(distanceWords) — move \(directionWords)"
        case .onTarget: "On target"
        case .lost: "Panel out of view — point the phone back at it"
        case .unclear: "Can't see the panel clearly — hold steady"
        case .cannotTrack: problemWords
        }
    }

    /// The ring's accessibility value.
    var spoken: String {
        switch phase {
        case .moving: "\(distanceWords). Move \(directionWords)."
        default: line.replacingOccurrences(of: " — ", with: ". ")
        }
    }

    var tint: Color {
        switch phase {
        case .onTarget: ContourTheme.Colors.success
        case .lost, .unclear, .cannotTrack: ContourTheme.Colors.warning
        default: ContourTheme.Colors.accent
        }
    }

    var symbol: String? {
        switch phase {
        case .starting: nil
        case .noFinger: "hand.point.up.left.fill"
        case .moving: "arrow.right"
        case .onTarget: "checkmark"
        case .lost: "viewfinder"
        case .unclear: "eye.trianglebadge.exclamationmark"
        case .cannotTrack: "exclamationmark.triangle.fill"
        }
    }
}

/// A ring that fills with proximity, around an arrow pointing the way.
private struct ProximityRing: View {
    let status: GuideStatus
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(ContourTheme.Colors.ringBackground)
            Circle()
                .stroke(ContourTheme.Colors.ringTrack, lineWidth: ContourTheme.Size.proximityRingLine)
            Circle()
                .trim(from: 0, to: status.fill)
                .stroke(status.tint, style: StrokeStyle(lineWidth: ContourTheme.Size.proximityRingLine,
                                                        lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let symbol = status.symbol {
                Image(systemName: symbol)
                    .font(.system(size: ContourTheme.Size.directionArrow * size / ContourTheme.Size.proximityRing,
                                  weight: .heavy))
                    .foregroundStyle(status.tint)
                    // +dy is down on the panel and on the screen: rotate as-is.
                    .rotationEffect(.radians(status.angle ?? 0))
                    // Snap rather than animate the turn, so crossing "left"
                    // (±π) never spins the arrow the long way round.
                    .animation(nil, value: status.angle)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(ContourTheme.Colors.textPrimary)
            }
        }
        .padding(ContourTheme.Size.proximityRingLine / 2)
        .frame(width: size, height: size)
        .animation(ContourTheme.Motion.guidance(reduceMotion: reduceMotion), value: status)
    }
}

#Preview("Can't track") {
    GuideScreen(
        target: SurfaceMap.Button(label: "Start", bounds: PanelRect(x: 0.38, y: 0.52, width: 0.24, height: 0.2),
                                  confidence: 0.97),
        guidance: .outcome(.lostTracking, at: .now),
        problem: "Couldn't lock onto the panel. Scan again with the whole panel in view.",
        onStop: {}, onRescan: {}
    ) {
        ViewfinderPlaceholder(message: "Camera unavailable in Simulator")
    }
}

#Preview("Guide") {
    GuideScreen(
        target: SurfaceMap.Button(label: "Start", bounds: PanelRect(x: 0.38, y: 0.52, width: 0.24, height: 0.2),
                                  confidence: 0.97),
        guidance: GuidanceState(timestamp: .now, vector: GuidanceVector(direction: PanelVector(dx: 0.6, dy: 0.8),
                                                                        normalizedDistance: 0.3)),
        onStop: {}
    ) {
        ViewfinderPlaceholder(message: "Camera unavailable in Simulator")
    }
}
