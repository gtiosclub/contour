//
//  TrackingQuality.swift
//  Tracking — Tracking / Tracking Assessment
//
//  Rates one frame of tracking: good / degraded / lost, plus a reason.
//  No detection, no reacquisition — just the judgement.
//

import ContourCore
import Foundation

/// What tracking saw this frame, before anyone judges it.
///
/// No fingertip *position* here on purpose: none of the checks need it, and
/// leaving it out means this works for both the image-space debug screen and
/// panel-space production without either faking the other's coordinates.
public struct TrackingObservation: Hashable, Sendable {
    public var timestamp: Date
    /// `nil` means no finger seen — not "seen at zero confidence".
    public var fingertipConfidence: Double?
    /// `nil` means the panel wasn't located. Corners are image space.
    public var panelQuad: PanelQuad?
    public var panelConfidence: Double

    public init(timestamp: Date, fingertipConfidence: Double? = nil,
                panelQuad: PanelQuad? = nil, panelConfidence: Double = 0) {
        self.timestamp = timestamp
        self.fingertipConfidence = fingertipConfidence
        self.panelQuad = panelQuad
        self.panelConfidence = panelConfidence
    }
}

public enum TrackingQualityReason: String, Hashable, Sendable, CaseIterable {
    case tracking
    case panelNotLocated
    case panelConfidenceLow
    case panelJumped
    case stale
    case noFingertip
    case fingertipConfidenceLow

    /// For logs and the debug screen.
    public var message: String {
        switch self {
        case .tracking: "Panel and fingertip tracked"
        case .panelNotLocated: "Panel not located"
        case .panelConfidenceLow: "Panel confidence below threshold"
        case .panelJumped: "Panel moved implausibly fast"
        case .stale: "Observation is stale"
        case .noFingertip: "No fingertip in view"
        case .fingertipConfidenceLow: "Fingertip confidence below threshold"
        }
    }
}

public struct TrackingAssessment: Hashable, Sendable {
    public var timestamp: Date
    public var quality: TrackingQuality
    public var reason: TrackingQualityReason

    public init(timestamp: Date, quality: TrackingQuality, reason: TrackingQualityReason) {
        self.timestamp = timestamp
        self.quality = quality
        self.reason = reason
    }

    /// "Degraded" — so debug UI doesn't need to import ContourCore.
    public var qualityLabel: String { quality.rawValue.capitalized }
    /// "Degraded — No fingertip in view"
    public var summary: String { "\(qualityLabel) — \(reason.message)" }
}

/// Starting values, all first guesses — calibrate against recorded fixtures.
public struct TrackingQualityThresholds: Hashable, Sendable {
    /// At or below this the panel is noise, not geometry.
    public var panelFloor = 0.30
    /// Between floor and this, geometry is usable but softened.
    public var panelGood = 0.60
    /// Vision hand-pose joints below this tend to be extrapolated, not seen.
    public var fingertipGood = 0.50
    /// ~4 frames at 30 fps: a real gap, but the finger hasn't moved far.
    public var staleDegraded: TimeInterval = 0.15
    /// Further than a reaching hand travels; this frame describes the past.
    public var staleLost: TimeInterval = 0.5
    /// Image widths per second. A hand-held pan crosses the frame in ~1s.
    public var maxCornerSpeed = 2.5
    /// Below this, dt is noise and the speed division explodes.
    public var minInterval: TimeInterval = 0.005
    /// The fingertip-only debug screen sets this false; production needs it.
    public var panelRequired = true

    public init() {}
}

/// Pure: same inputs, same verdict. Callers keep the previous observation.
public struct TrackingQualityEvaluator: Sendable {
    public var thresholds: TrackingQualityThresholds

    public init(thresholds: TrackingQualityThresholds = TrackingQualityThresholds()) {
        self.thresholds = thresholds
    }

    /// Rate `observation`, most severe check first.
    ///
    /// - Parameters:
    ///   - previous: the frame before, for the jump check. `nil` skips it.
    ///   - now: what staleness is measured against. Defaults to the
    ///     observation's own timestamp; pass `Date()` live to catch lag.
    public func assess(_ observation: TrackingObservation,
                       previous: TrackingObservation? = nil,
                       asOf now: Date? = nil) -> TrackingAssessment {
        let age = (now ?? observation.timestamp).timeIntervalSince(observation.timestamp)

        if age >= thresholds.staleLost {
            return verdict(observation, .lost, .stale)
        }
        if observation.panelQuad == nil && thresholds.panelRequired {
            // No panel means no panel space, so there's nothing to report a
            // finger in.
            return verdict(observation, .lost, .panelNotLocated)
        }
        if observation.panelQuad != nil {
            if observation.panelConfidence <= thresholds.panelFloor {
                return verdict(observation, .lost, .panelConfidenceLow)
            }
            // Lost, not degraded: a mis-latched panel gives a confident
            // fingertip at the wrong coordinate, which is the one failure that
            // sends a hand to the wrong button.
            if jumped(from: previous, to: observation) {
                return verdict(observation, .lost, .panelJumped)
            }
        }
        // Panel still tracked below here, so these soften rather than stop.
        guard let fingertip = observation.fingertipConfidence else {
            return verdict(observation, .degraded, .noFingertip)
        }
        if fingertip < thresholds.fingertipGood {
            return verdict(observation, .degraded, .fingertipConfidenceLow)
        }
        if observation.panelQuad != nil, observation.panelConfidence < thresholds.panelGood {
            return verdict(observation, .degraded, .panelConfidenceLow)
        }
        if age >= thresholds.staleDegraded {
            return verdict(observation, .degraded, .stale)
        }
        return verdict(observation, .good, .tracking)
    }

    private func verdict(_ observation: TrackingObservation, _ quality: TrackingQuality,
                         _ reason: TrackingQualityReason) -> TrackingAssessment {
        TrackingAssessment(timestamp: observation.timestamp, quality: quality, reason: reason)
    }

    /// `false` whenever the comparison can't be made — duplicate and slightly
    /// out-of-order timestamps are legal, and neither is a tracking failure.
    private func jumped(from previous: TrackingObservation?,
                        to observation: TrackingObservation) -> Bool {
        guard let previous, let start = previous.panelQuad,
              let end = observation.panelQuad else { return false }
        let dt = observation.timestamp.timeIntervalSince(previous.timestamp)
        guard dt >= thresholds.minInterval else { return false }
        return Self.cornerShift(start, end) / dt > thresholds.maxCornerSpeed
    }

    /// Per corner, by logical identity: a quad that keeps its centre while its
    /// corners fold over is exactly the mis-latch we're looking for.
    static func cornerShift(_ a: PanelQuad, _ b: PanelQuad) -> Double {
        [(a.topLeft, b.topLeft), (a.topRight, b.topRight),
         (a.bottomRight, b.bottomRight), (a.bottomLeft, b.bottomLeft)]
            .map { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) }
            .max() ?? 0
    }
}