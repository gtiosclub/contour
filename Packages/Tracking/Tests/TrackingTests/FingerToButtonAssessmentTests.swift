
//
//  FingerToButtonAssessmentTests.swift
//  TrackingTests
//
//  Camera-independent tests for assessed finger-to-button positions.
//

import ContourCore
import Foundation
import Testing
@testable import Tracking

@Suite("Finger-to-button assessment")
struct FingerToButtonAssessmentTests {

    private let assessor = FingerToButtonAssessor()
    private let timestamp = Date(timeIntervalSince1970: 100)

    // MARK: - Fixtures

    private func observation(
        at time: Date? = nil,
        fingertipConfidence: Double? = 0.9,
        panelConfidence: Double = 0.9,
        quad: PanelQuad? = .fullFrame
    ) -> TrackingObservation {
        TrackingObservation(
            timestamp: time ?? timestamp,
            fingertipConfidence: fingertipConfidence,
            panelQuad: quad,
            panelConfidence: panelConfidence
        )
    }

    private func button(
        id: UUID = UUID(),
        x: Double = 0.4,
        y: Double = 0.4,
        width: Double = 0.2,
        height: Double = 0.2
    ) -> SurfaceMap.Button {
        SurfaceMap.Button(
            id: id,
            label: "Test button",
            bounds: PanelRect(
                x: x,
                y: y,
                width: width,
                height: height
            ),
            confidence: 0.95
        )
    }

    private func point(
        _ x: Double = 0.5,
        _ y: Double = 0.5
    ) -> PanelPoint {
        PanelPoint(x: x, y: y)
    }

    private func assess(
        _ fingertip: PanelPoint?,
        _ selectedButton: SurfaceMap.Button? = nil,
        observation: TrackingObservation? = nil,
        previous: TrackingObservation? = nil,
        now: Date? = nil
    ) -> FingerToButtonResult {
        assessor.assess(
            fingertip: fingertip,
            button: selectedButton,
            observation: observation ?? self.observation(),
            previous: previous,
            asOf: now ?? timestamp
        )
    }

    private func shiftedQuad(_ amount: Double) -> PanelQuad {
        PanelQuad(
            topLeft: ImagePoint(x: amount, y: amount),
            topRight: ImagePoint(x: 1 + amount, y: amount),
            bottomRight: ImagePoint(x: 1 + amount, y: 1 + amount),
            bottomLeft: ImagePoint(x: amount, y: 1 + amount)
        )
    }

    private func quad(
        topLeft: ImagePoint = ImagePoint(x: 0, y: 0),
        topRight: ImagePoint = ImagePoint(x: 1, y: 0),
        bottomRight: ImagePoint = ImagePoint(x: 1, y: 1),
        bottomLeft: ImagePoint = ImagePoint(x: 0, y: 1)
    ) -> PanelQuad {
        PanelQuad(
            topLeft: topLeft,
            topRight: topRight,
            bottomRight: bottomRight,
            bottomLeft: bottomLeft
        )
    }

    // MARK: - Valid spatial results

    @Test("Fingertip at button center produces zero distance")
    func buttonCenter() {
        let target = button()
        let result = assess(point(), target)

        #expect(result.quality == .good)
        #expect(result.fingertip == point())
        #expect(result.buttonID == target.id)
        #expect(result.offset == .zero)
        #expect(result.distance == 0)
        #expect(result.containsFingertip == true)
        #expect(result.hasButtonPosition)
        #expect(result.unavailableReason == nil)
    }

    @Test("Known positions produce correct offset and distance")
    func knownPosition() {
        let target = button(
            x: 0.5,
            y: 0.5,
            width: 0.2,
            height: 0.2
        )

        let result = assess(point(0.2, 0.3), target)

        #expect(abs(result.offset!.dx - 0.4) < 0.000001)
        #expect(abs(result.offset!.dy - 0.3) < 0.000001)
        #expect(abs(result.distance! - 0.5) < 0.000001)
        #expect(result.containsFingertip == false)
    }

    @Test("Button containment includes rectangle edges")
    func buttonEdges() {
        let target = button(
            x: 0.4,
            y: 0.4,
            width: 0.2,
            height: 0.2
        )

        let result = assess(point(0.4, 0.4), target)

        #expect(result.containsFingertip == true)
        #expect(result.distance != nil)
    }

    @Test("Off-panel coordinates are preserved without clamping")
    func offPanelCoordinates() {
        let fingertip = point(1.2, -0.2)
        let result = assess(fingertip)

        #expect(result.fingertip == fingertip)
        #expect(result.fingertip?.x == 1.2)
        #expect(result.fingertip?.y == -0.2)
        #expect(result.hasUsableFingertip)
    }

    @Test("Capture timestamp is preserved")
    func captureTimestamp() {
        let captureTime = Date(timeIntervalSince1970: 123)
        let result = assess(
            point(),
            observation: observation(at: captureTime),
            now: timestamp
        )

        #expect(result.timestamp == captureTime)
        #expect(result.assessment.timestamp == captureTime)
    }

    // MARK: - Missing input

    @Test("Missing fingertip withholds all spatial values")
    func missingFingertip() {
        let result = assess(nil, button())

        #expect(result.fingertip == nil)
        #expect(result.buttonID == nil)
        #expect(result.offset == nil)
        #expect(result.distance == nil)
        #expect(result.containsFingertip == nil)
        #expect(result.unavailableReason == .missingFingertip)
    }

    @Test("Missing panel withholds all spatial values")
    func missingPanel() {
        let result = assess(
            point(),
            button(),
            observation: observation(quad: nil)
        )

        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(result.unavailableReason == .missingPanel)
    }

    @Test("Valid fingertip without a button remains available")
    func missingSelectedButton() {
        let fingertip = point()
        let result = assess(fingertip)

        #expect(result.fingertip == fingertip)
        #expect(result.hasUsableFingertip)
        #expect(result.buttonID == nil)
        #expect(result.offset == nil)
        #expect(result.distance == nil)
        #expect(result.containsFingertip == nil)
        #expect(result.unavailableReason == .noSelectedButton)
    }

    // MARK: - Confidence

    @Test("Low fingertip confidence withholds spatial values")
    func lowFingertipConfidence() {
        let result = assess(
            point(),
            button(),
            observation: observation(fingertipConfidence: 0.2)
        )

        #expect(result.quality == .degraded)
        #expect(result.qualityReason == .fingertipConfidenceLow)
        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(
            result.unavailableReason ==
            .trackingUnavailable(.fingertipConfidenceLow)
        )
    }

    @Test("Missing fingertip confidence withholds spatial values")
    func missingFingertipConfidence() {
        let result = assess(
            point(),
            button(),
            observation: observation(fingertipConfidence: nil)
        )

        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(
            result.unavailableReason ==
            .trackingUnavailable(.noFingertip)
        )
    }

    @Test("Degraded panel confidence can still supply spatial values")
    func degradedPanelConfidence() {
        let target = button()

        let result = assess(
            point(),
            target,
            observation: observation(panelConfidence: 0.45)
        )

        #expect(result.quality == .degraded)
        #expect(result.qualityReason == .panelConfidenceLow)
        #expect(result.fingertip == point())
        #expect(result.buttonID == target.id)
        #expect(result.distance == 0)
        #expect(result.hasButtonPosition)
    }

    @Test("Panel confidence at the lost threshold withholds spatial values")
    func panelConfidenceAtFloor() {
        let result = assess(
            point(),
            button(),
            observation: observation(panelConfidence: 0.3)
        )

        #expect(result.quality == .lost)
        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(
            result.unavailableReason ==
            .trackingUnavailable(.panelConfidenceLow)
        )
    }

    @Test("Non-finite fingertip confidence is rejected")
    func nonFiniteFingertipConfidence() {
        for confidence in [Double.nan, .infinity, -.infinity] {
            let result = assess(
                point(),
                button(),
                observation: observation(fingertipConfidence: confidence)
            )

            #expect(result.fingertip == nil)
            #expect(result.distance == nil)
            #expect(result.unavailableReason == .nonFiniteConfidence)
        }
    }

    @Test("Non-finite panel confidence is rejected")
    func nonFinitePanelConfidence() {
        for confidence in [Double.nan, .infinity, -.infinity] {
            let result = assess(
                point(),
                button(),
                observation: observation(panelConfidence: confidence)
            )

            #expect(result.fingertip == nil)
            #expect(result.distance == nil)
            #expect(result.unavailableReason == .nonFiniteConfidence)
        }
    }

    @Test("Out-of-range confidence is rejected")
    func invalidConfidence() {
        for confidence in [-0.1, 1.1] {
            let result = assess(
                point(),
                button(),
                observation: observation(fingertipConfidence: confidence)
            )

            #expect(result.fingertip == nil)
            #expect(result.distance == nil)
            #expect(result.unavailableReason == .invalidConfidence)
        }
    }

    // MARK: - Non-finite geometry

    @Test("Non-finite fingertip coordinates are rejected")
    func nonFiniteFingertip() {
        let invalidPoints = [
            point(.nan, 0.5),
            point(.infinity, 0.5),
            point(0.5, .nan),
            point(0.5, -.infinity)
        ]

        for fingertip in invalidPoints {
            let result = assess(fingertip, button())

            #expect(result.fingertip == nil)
            #expect(result.distance == nil)
            #expect(result.unavailableReason == .nonFiniteFingertip)
        }
    }

    @Test("Non-finite button geometry is rejected")
    func nonFiniteButtonGeometry() {
        let invalidButton = button(
            x: .nan,
            y: 0.4,
            width: 0.2,
            height: 0.2
        )

        let result = assess(point(), invalidButton)

        #expect(result.fingertip == point())
        #expect(result.buttonID == nil)
        #expect(result.distance == nil)
        #expect(result.unavailableReason == .nonFiniteButtonGeometry)
    }

    @Test("Every panel corner rejects non-finite coordinates")
    func nonFinitePanelCorners() {
        let invalidQuads = [
            quad(topLeft: ImagePoint(x: .nan, y: 0)),
            quad(topRight: ImagePoint(x: 1, y: .infinity)),
            quad(bottomRight: ImagePoint(x: -.infinity, y: 1)),
            quad(bottomLeft: ImagePoint(x: 0, y: .nan))
        ]

        for invalidQuad in invalidQuads {
            let result = assess(
                point(),
                button(),
                observation: observation(quad: invalidQuad)
            )

            #expect(result.fingertip == nil)
            #expect(result.buttonID == nil)
            #expect(result.offset == nil)
            #expect(result.distance == nil)
            #expect(result.containsFingertip == nil)
            #expect(
                result.unavailableReason == .nonFinitePanelGeometry
            )
        }
    }

    @Test("Negative infinity in panel corner is rejected")
    func negativeInfinityPanelCorner() {
        let invalidQuad = quad(
            bottomLeft: ImagePoint(x: 0, y: -.infinity)
        )

        let result = assess(
            point(),
            button(),
            observation: observation(quad: invalidQuad)
        )

        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(result.unavailableReason == .nonFinitePanelGeometry)
    }

    // MARK: - Staleness and panel jumps

    @Test("Stale observations withhold all spatial values")
    func staleObservation() {
        let result = assess(
            point(),
            button(),
            now: timestamp.addingTimeInterval(1)
        )

        #expect(result.quality == .lost)
        #expect(result.qualityReason == .stale)
        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(
            result.unavailableReason ==
            .trackingUnavailable(.stale)
        )
    }

    @Test("Degraded stale observations withhold spatial values")
    func degradedStaleObservation() {
        let result = assess(
            point(),
            button(),
            observation: observation(panelConfidence: 0.45),
            now: timestamp.addingTimeInterval(0.2)
        )

        #expect(result.quality == .degraded)
        #expect(result.qualityReason == .panelConfidenceLow)
        #expect(result.fingertip == nil)
        #expect(result.buttonID == nil)
        #expect(result.offset == nil)
        #expect(result.distance == nil)
        #expect(result.containsFingertip == nil)
        #expect(
            result.unavailableReason ==
            .trackingUnavailable(.stale)
        )
    }

    @Test("Degraded stale observations withhold spatial values")
    func degradedStaleObservationFromEvaluator() {
        let result = assess(
            point(),
            button(),
            now: timestamp.addingTimeInterval(0.2)
        )

        #expect(result.quality == .degraded)
        #expect(result.qualityReason == .stale)
        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
    }

    @Test("Implausible panel jump withholds spatial values")
    func panelJump() {
        let previous = observation(
            at: timestamp,
            quad: .fullFrame
        )

        let current = observation(
            at: timestamp.addingTimeInterval(0.1),
            quad: shiftedQuad(0.5)
        )

        let result = assess(
            point(),
            button(),
            observation: current,
            previous: previous,
            now: timestamp.addingTimeInterval(0.1)
        )

        #expect(result.quality == .lost)
        #expect(result.qualityReason == .panelJumped)
        #expect(result.fingertip == nil)
        #expect(result.distance == nil)
        #expect(
            result.unavailableReason ==
            .trackingUnavailable(.panelJumped)
        )
    }

    // MARK: - Target changes and fresh results

    @Test("Changing selected button updates identity and values")
    func changingTargets() {
        let leftID = UUID()
        let rightID = UUID()

        let left = button(
            id: leftID,
            x: 0.0,
            y: 0.0,
            width: 0.2,
            height: 0.2
        )

        let right = button(
            id: rightID,
            x: 0.8,
            y: 0.8,
            width: 0.2,
            height: 0.2
        )

        let fingertip = point(0.2, 0.1)
        
        let first = assess(fingertip, left)
        let second = assess(fingertip, right)

        #expect(first.buttonID == leftID)
        #expect(second.buttonID == rightID)
        #expect(first.offset != second.offset)
        #expect(first.distance != second.distance)
    }

    @Test("Valid invalid valid never reuses previous spatial values")
    func validInvalidValid() {
        let target = button()
        let fingertip = point()

        let first = assess(fingertip, target)
        let invalid = assess(nil, target)
        let recovered = assess(fingertip, target)

        #expect(first.hasButtonPosition)

        #expect(invalid.fingertip == nil)
        #expect(invalid.buttonID == nil)
        #expect(invalid.offset == nil)
        #expect(invalid.distance == nil)
        #expect(invalid.containsFingertip == nil)

        #expect(recovered.hasButtonPosition)
        #expect(recovered.distance == 0)
        #expect(recovered.buttonID == target.id)
    }
}
