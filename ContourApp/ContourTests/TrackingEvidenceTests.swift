import ContourCore
import CoreVideo
import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Tracking diagnostic evidence")
struct TrackingEvidenceTests {
    @Test("Calibration readiness never substitutes for the returned source", arguments: [
        HybridTrackingDiagnostics.Source.visual, .fused, .world, .unavailable
    ])
    func sourceAndReadiness(source: HybridTrackingDiagnostics.Source) throws {
        let hybrid = HybridTrackingDiagnostics(mode: .corrected, message: "Move sideways to confirm depth",
            calibrationFrames: 8, source: source, calibrationReady: true)
        let evidence = TrackingEvidence(sample: try sample(hybrid: hybrid))
        #expect(evidence.source == source)
        #expect(evidence.calibration.first { $0.label == "Readiness" }?.value == "Ready")
        #expect(evidence.explanations.contains("Move sideways to confirm depth"))
    }

    @Test("Missing evidence stays unavailable instead of asserting zero measurements")
    func missingEvidence() throws {
        let evidence = TrackingEvidence(sample: try sample())
        #expect(evidence.source == nil)
        #expect(evidence.calibration.allSatisfy { $0.value == "Unavailable" })
        #expect(evidence.features.allSatisfy { $0.value == "Unavailable" })
        #expect(TrackingEvidence(sample: nil).source == nil)
    }

    @Test("Rejected geometry cannot claim world prediction even when calibration remains ready")
    func lostGeometry() throws {
        let hybrid = HybridTrackingDiagnostics(mode: .predicted, message: "Ready", calibrationFrames: 8,
            source: .world, calibrationReady: true)
        let evidence = TrackingEvidence(sample: try sample(hybrid: hybrid, quad: nil))
        #expect(evidence.source == .unavailable)
        #expect(evidence.calibration.first { $0.label == "Readiness" }?.value == "Ready")
    }

    @Test("Feature evidence exposes counts, errors and heuristic glare without inventing invalid measurements")
    func featureEvidence() throws {
        let feature = FeatureTrackingDiagnostics(referenceFeatures: 120, frameFeatures: 90,
            matchCount: 40, inlierCount: 28, coverage: 0.25, reprojectionError: .infinity,
            processingMilliseconds: 12.5, message: "Weak texture", inlierPoints: [],
            saturatedFraction: 0.2, excludedHighlightFraction: .nan)
        let hybrid = HybridTrackingDiagnostics(mode: .calibrating, message: "More movement needed",
            calibrationFrames: 3, stableFeatures: 19, repositionReason: .suspectedGlare,
            resetCount: 2, lastResetReason: "Plane changed", alignmentError: .nan,
            baselineCentimeters: 4.5, visualVerificationAge: -1)
        let evidence = TrackingEvidence(sample: try sample(hybrid: hybrid, feature: feature))
        #expect(evidence.features.first { $0.label == "Reference features" }?.value == "120")
        #expect(evidence.features.first { $0.label == "Inliers" }?.value == "28")
        #expect(evidence.features.first { $0.label == "Coverage" }?.value == "25.0%")
        #expect(evidence.features.first { $0.label == "Reprojection error" }?.value == "Unavailable")
        #expect(evidence.features.first { $0.label == "Excluded highlights" }?.value == "Unavailable")
        #expect(evidence.calibration.first { $0.label == "Last visual verification" }?.value == "Unavailable")
        #expect(evidence.calibration.first { $0.label == "Reset reason" }?.value == "Plane changed")
        #expect(evidence.explanations.contains { $0.contains("heuristic") })
        #expect(evidence.explanations.contains("Weak texture"))
    }

    @Test("Surface rejection evidence distinguishes missing planes from incomplete coverage")
    func surfaceEvidence() throws {
        let hybrid = HybridTrackingDiagnostics(mode: .visual, message: "Show surrounding surface",
            calibrationFrames: 0, surfaceSelection: .init(detectedPlaneCount: 2,
                fittingPlaneCount: 0, rejections: [.outsidePlaneExtent: 2]))
        let evidence = TrackingEvidence(sample: try sample(hybrid: hybrid))
        #expect(evidence.calibration.first { $0.label == "AR planes" }?.value == "2")
        #expect(evidence.calibration.first { $0.label == "Fitting planes" }?.value == "0")
        #expect(evidence.calibration.first { $0.label == "Surface rejections" }?.value.contains("cover") == true)
        let waiting = HybridTrackingDiagnostics(mode: .calibrating, message: "Hold",
            calibrationFrames: 2, surfaceSelection: .init(detectedPlaneCount: 0))
        let held = TrackingEvidence(sample: try sample(hybrid: waiting))
        #expect(held.calibration.first { $0.label == "AR planes" }?.value == "0")
        #expect(held.calibration.first { $0.label == "Fitting planes" }?.value == "Unavailable")
        #expect(held.calibration.first { $0.label == "Surface rejections" }?.value == "Unavailable")
    }

    private func sample(hybrid: HybridTrackingDiagnostics? = nil,
                        feature: FeatureTrackingDiagnostics? = nil,
                        quad: PanelQuad? = .fullFrame) throws -> LiveTrackingSample {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA, nil, &buffer)
        let timestamp = Date()
        return LiveTrackingSample(cameraFrame: CameraFrame(pixelBuffer: try #require(buffer), timestamp: timestamp),
            frame: TrackingFrame(timestamp: timestamp, fingertip: nil, panel: .unknown,
                                 trackingQuality: quad == nil ? .lost : .good),
            panelQuad: quad, featureDiagnostics: feature, hybridDiagnostics: hybrid)
    }
}
