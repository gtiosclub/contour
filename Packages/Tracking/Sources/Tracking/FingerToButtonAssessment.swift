//
//  FingerToButtonAssessment.swift
//  Tracking — Tracking / Spatial Output
//
//  Produces assessed finger-to-button spatial results.
//  Camera-independent: accepts panel-space coordinates only.
//

import ContourCore
import Foundation

/// Explains why fingertip or button-relative spatial data is unavailable.
public enum FingerToButtonUnavailableReason: Hashable, Sendable {
    case missingPanel
    case missingFingertip
    case nonFiniteFingertip
    case nonFiniteConfidence
    case invalidConfidence
    case trackingUnavailable(TrackingQualityReason)
    case noSelectedButton
    case nonFiniteButtonGeometry
}

/// Result for one assessed tracking observation.
///
/// Distance and offset are expressed in normalized panel units.
/// No spatial values are retained from previous assessments.
public struct FingerToButtonResult: Hashable, Sendable {
    /// Original observation capture timestamp.
    public let timestamp: Date

    /// Quality assessment produced by TrackingQualityEvaluator.
    public let assessment: TrackingAssessment

    /// Usable fingertip position in normalized panel space.
    public let fingertip: PanelPoint?

    /// Identity of the selected button, when spatial values are available.
    public let buttonID: UUID?

    /// Vector from fingertip to button center.
    public let offset: PanelVector?

    /// Euclidean distance to button center, in normalized panel units.
    public let distance: Double?

    /// Whether the fingertip is inside the button bounds.
    public let containsFingertip: Bool?

    /// Explicit reason why spatial output is unavailable.
    public let unavailableReason: FingerToButtonUnavailableReason?

    /// Convenience access to tracking quality.
    public var quality: TrackingQuality {
        assessment.quality
    }

    /// Convenience access to the tracking quality reason.
    public var qualityReason: TrackingQualityReason {
        assessment.reason
    }

    /// Whether the fingertip itself is usable.
    public var hasUsableFingertip: Bool {
        fingertip != nil
    }

    /// Whether all button-relative values are available.
    public var hasButtonPosition: Bool {
        buttonID != nil &&
        offset != nil &&
        distance != nil &&
        containsFingertip != nil
    }
}

/// Assesses a panel-space fingertip relative to a selected button.
///
/// This component does not perform detection, coordinate mapping,
/// reacquisition, smoothing, or target selection.
public struct FingerToButtonAssessor: Sendable {
    private let evaluator: TrackingQualityEvaluator

    public init(
        thresholds: TrackingQualityThresholds = TrackingQualityThresholds()
    ) {
        self.evaluator = TrackingQualityEvaluator(thresholds: thresholds)
    }

    /// Produces a fresh finger-to-button result for one observation.
    ///
    /// - Parameters:
    ///   - fingertip: Current fingertip in normalized panel space.
    ///   - button: Currently selected button, if any.
    ///   - observation: Tracking observation for this frame.
    ///   - previous: Previous observation, used for panel jump detection.
    ///   - now: Explicit evaluation time used for staleness.
    ///
    /// Spatial output policy:
    /// - Lost tracking never supplies spatial values.
    /// - Missing panel or fingertip never supplies spatial values.
    /// - Non-finite coordinates or confidence are rejected.
    /// - Low fingertip confidence never supplies spatial values.
    /// - Stale evidence never supplies spatial values.
    /// - Degraded panel confidence may supply spatial values if the
    ///   fingertip is reliable and the evaluator accepts the panel.
    /// - A valid fingertip without a button remains available.
    /// - Off-panel coordinates are preserved without clamping.
    public func assess(
        fingertip: PanelPoint?,
        button: SurfaceMap.Button?,
        observation: TrackingObservation,
        previous: TrackingObservation? = nil,
        asOf now: Date
    ) -> FingerToButtonResult {

        let assessment = evaluator.assess(
            observation,
            previous: previous,
            asOf: now
        )

        // A located panel is mandatory for production panel-space output.
        guard observation.panelQuad != nil else {
            return unavailable(
                observation,
                assessment,
                .missingPanel
            )
        }

        // Reject invalid confidence values explicitly.
        if let confidence = observation.fingertipConfidence {
            guard confidence.isFinite else {
                return unavailable(
                    observation,
                    assessment,
                    .nonFiniteConfidence
                )
            }

            guard (0...1).contains(confidence) else {
                return unavailable(
                    observation,
                    assessment,
                    .invalidConfidence
                )
            }
        }

        guard observation.panelConfidence.isFinite else {
            return unavailable(
                observation,
                assessment,
                .nonFiniteConfidence
            )
        }

        guard (0...1).contains(observation.panelConfidence) else {
            return unavailable(
                observation,
                assessment,
                .invalidConfidence
            )
        }

        // Require a current fingertip position.
        guard let fingertip else {
            return unavailable(
                observation,
                assessment,
                .missingFingertip
            )
        }

        guard fingertip.x.isFinite, fingertip.y.isFinite else {
            return unavailable(
                observation,
                assessment,
                .nonFiniteFingertip
            )
        }

        // The evaluator's good assessment is usable.
        // Degraded panel confidence is also usable, provided the
        // fingertip is reliable.
        let assessmentAllowsSpatialOutput =
            assessment.quality == .good ||
            (
                assessment.quality == .degraded &&
                assessment.reason == .panelConfidenceLow
            )

        guard assessmentAllowsSpatialOutput else {
            return unavailable(
                observation,
                assessment,
                .trackingUnavailable(assessment.reason)
            )
        }

        // The actual fingertip must meet the evaluator's existing threshold.
        guard let confidence = observation.fingertipConfidence else {
            return unavailable(
                observation,
                assessment,
                .trackingUnavailable(.noFingertip)
            )
        }

        guard confidence >= evaluator.thresholds.fingertipGood else {
            return unavailable(
                observation,
                assessment,
                .trackingUnavailable(.fingertipConfidenceLow)
            )
        }

        // A valid fingertip is useful even without a selected button.
        guard let button else {
            return FingerToButtonResult(
                timestamp: observation.timestamp,
                assessment: assessment,
                fingertip: fingertip,
                buttonID: nil,
                offset: nil,
                distance: nil,
                containsFingertip: nil,
                unavailableReason: .noSelectedButton
            )
        }

        let bounds = button.bounds

        // Reject malformed or non-finite button geometry.
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width >= 0,
              bounds.height >= 0,
              bounds.maxX.isFinite,
              bounds.maxY.isFinite else {
            return FingerToButtonResult(
                timestamp: observation.timestamp,
                assessment: assessment,
                fingertip: fingertip,
                buttonID: nil,
                offset: nil,
                distance: nil,
                containsFingertip: nil,
                unavailableReason: .nonFiniteButtonGeometry
            )
        }

        let center = bounds.center

        guard center.x.isFinite, center.y.isFinite else {
            return FingerToButtonResult(
                timestamp: observation.timestamp,
                assessment: assessment,
                fingertip: fingertip,
                buttonID: nil,
                offset: nil,
                distance: nil,
                containsFingertip: nil,
                unavailableReason: .nonFiniteButtonGeometry
            )
        }

        // Button center minus fingertip.
        let offset = fingertip.vector(to: center)
        let distance = offset.magnitude

        guard offset.dx.isFinite,
              offset.dy.isFinite,
              distance.isFinite else {
            return FingerToButtonResult(
                timestamp: observation.timestamp,
                assessment: assessment,
                fingertip: fingertip,
                buttonID: nil,
                offset: nil,
                distance: nil,
                containsFingertip: nil,
                unavailableReason: .nonFiniteButtonGeometry
            )
        }

        return FingerToButtonResult(
            timestamp: observation.timestamp,
            assessment: assessment,
            fingertip: fingertip,
            buttonID: button.id,
            offset: offset,
            distance: distance,
            containsFingertip: bounds.contains(fingertip),
            unavailableReason: nil
        )
    }

    /// Creates an unavailable result without retaining spatial values.
    private func unavailable(
        _ observation: TrackingObservation,
        _ assessment: TrackingAssessment,
        _ reason: FingerToButtonUnavailableReason
    ) -> FingerToButtonResult {
        FingerToButtonResult(
            timestamp: observation.timestamp,
            assessment: assessment,
            fingertip: nil,
            buttonID: nil,
            offset: nil,
            distance: nil,
            containsFingertip: nil,
            unavailableReason: reason
        )
    }
}
