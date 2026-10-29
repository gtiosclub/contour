import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Guidance status display")
struct GuidanceStatusDisplayTests {
    @Test("Actual source stays separate from calibration readiness and missing measurements")
    func suppliedEvidence() {
        let paused = HybridTrackingDiagnostics(mode: .reacquiring,
            message: "Prediction paused while the panel is checked.", calibrationFrames: 12,
            source: .unavailable, calibrationReady: true)
        let unavailable = GuidanceStatusSnapshot(diagnostics: paused)
        #expect(unavailable.source == "No usable alignment")
        #expect(unavailable.calibration == "Calibration ready")
        #expect(unavailable.verification == "Last visual check: unavailable")
        let retained = HybridTrackingDiagnostics(mode: .predicted, message: "", calibrationFrames: 12,
            source: .unavailable, calibrationReady: true)
        #expect(!GuidanceStatusSnapshot(diagnostics: retained).message.contains("prediction"))

        let predicted = HybridTrackingDiagnostics(mode: .predicted,
            message: "Using a recent world estimate.", calibrationFrames: 12,
            source: .world, calibrationReady: true, visualVerificationAge: 1.25)
        let available = GuidanceStatusSnapshot(diagnostics: predicted)
        #expect(available.source == "AR prediction")
        #expect(available.verification.contains("ago"))
        #expect(!available.verification.contains("unavailable"))
        #expect(available.message == "Using a recent world estimate.")
    }

    @Test("Unchanged evidence does not consume a publication interval")
    func unchangedEvidence() {
        let display = GuidanceStatusDisplay()
        let start = ContinuousClock.now
        let first = GuidanceStatusSnapshot(source: "Visual", calibration: "Building", verification: "Unavailable", message: "Visible")
        let second = GuidanceStatusSnapshot(source: "Prediction", calibration: "Ready", verification: "Recent", message: "Covered")
        display.receive(first)
        display.publishIfDue(at: start)
        display.receive(first)
        display.publishIfDue(at: start.advanced(by: .milliseconds(100)))
        display.receive(second)
        display.publishIfDue(at: start.advanced(by: .milliseconds(150)))
        #expect(display.current == second)
    }

    @Test("Unknown or invalid verification ages are never shown as measurements")
    func unknownVerification() {
        for age in [Double.nan, Double.infinity, -1] {
            let evidence = HybridTrackingDiagnostics(mode: .visual, message: "Visible", calibrationFrames: 1,
                visualVerificationAge: age)
            #expect(GuidanceStatusSnapshot(diagnostics: evidence).verification.contains("unavailable"))
        }
    }

    @Test("Display coalesces rapid changes and clears pending old-session evidence")
    func boundedPublicationAndReset() {
        let display = GuidanceStatusDisplay()
        let start = ContinuousClock.now
        let visual = GuidanceStatusSnapshot(diagnostics: HybridTrackingDiagnostics(
            mode: .visual, message: "Panel visible", calibrationFrames: 0, source: .visual))
        let predicted = GuidanceStatusSnapshot(diagnostics: HybridTrackingDiagnostics(
            mode: .predicted, message: "Prediction", calibrationFrames: 4, source: .world))
        let lost = GuidanceStatusSnapshot(diagnostics: HybridTrackingDiagnostics(
            mode: .reacquiring, message: "Panel lost", calibrationFrames: 4, source: .unavailable))

        display.receive(visual)
        display.publishIfDue(at: start)
        #expect(display.current == visual)
        display.receive(predicted)
        display.receive(lost)
        display.publishIfDue(at: start.advanced(by: .milliseconds(50)))
        #expect(display.current == visual)
        display.publishIfDue(at: start.advanced(by: .milliseconds(100)))
        #expect(display.current == lost)

        display.receive(predicted)
        display.reset()
        display.publishIfDue(at: start.advanced(by: .seconds(1)))
        #expect(display.current == .waiting)
    }
}
