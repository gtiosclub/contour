
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
    case nonFinitePanelGeometry
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
    public let timestamp: Date
    public let assessment: TrackingAssessment
    public let fingertip: PanelPoint?
    public let buttonID: UUID?
    public let offset: PanelVector?
    public let distance: Double?
    public let containsFingertip: Bool?
    public let unavailableReason: FingerToButtonUnavailableReason?

    public var quality: TrackingQuality {
        assessment.quality
    }

    public var qualityReason: TrackingQualityReason {
        assessment.reason
    }

    public var hasUsableFingertip: Bool {
        fingertip != nil
    }

    public var hasButtonPosition: Bool {
        buttonID != nil &&
        offset != nil &&
        distance != nil &&
        containsFingertip != nil
    }
}

/// Assesses a panel-space fingertip relative to a selected button.
///
/// Spatial output policy:
/// - Lost tracking never supplies spatial values.
/// - Missing panel or fingertip never supplies spatial values.
/// - Non-finite coordinates or confidence are rejected.
/// - Low fingertip confidence never supplies spatial values.
/// - Evidence at or beyond staleDegraded never supplies spatial values.
/// - Degraded panel confidence may supply spatial values when the
///   fingertip is reliable and the observation is fresh.
/// - A valid fingertip without a button remains available.
/// - Off-panel coordinates are preserved without clamping.
public struct FingerToButtonAssessor: Sendable {
    private let evaluator: TrackingQualityEvaluator

    public init(
        thresholds: TrackingQualityThresholds = TrackingQualityThresholds()
    ) {
        self.evaluator = TrackingQualityEvaluator(thresholds: thresholds)
    }

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

        guard let quad = observation.panelQuad else {
            return unavailable(observation, assessment, .missingPanel)
        }

        // Validate every image-space panel corner.
        let corners = [
            quad.topLeft,
            quad.topRight,
            quad.bottomRight,
            quad.bottomLeft
        ]

        guard corners.allSatisfy({
            $0.x.isFinite && $0.y.isFinite
        }) else {
            return unavailable(
                observation,
                assessment,
                .nonFinitePanelGeometry
            )
        }

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

        // Enforce freshness independently of the evaluator's first
        // matching quality reason. A degraded panel-confidence result
        // must not bypass the stale threshold.
        let age = now.timeIntervalSince(observation.timestamp)

        guard age < evaluator.thresholds.staleDegraded else {
            return unavailable(
                observation,
                assessment,
                .trackingUnavailable(.stale)
            )
        }

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

        // A valid fingertip remains useful without a selected button.
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
