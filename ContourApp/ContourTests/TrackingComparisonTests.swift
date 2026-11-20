import Foundation
import Testing
import Tracking
@testable import ContourApp

@MainActor
@Suite("Diagnostic comparison controls")
struct TrackingComparisonTests {
    @Test("Unsupported exposure never calls the camera or claims an applied bias")
    func unsupportedExposure() async {
        var requests: [Float] = []
        let controls = TrackingComparisonModel(supportsManualExposure: false,
            setExposure: { requests.append($0); return $0 }, requestSettings: { _, _ in })
        await controls.applyExposure(-0.7)
        #expect(requests.isEmpty)
        #expect(controls.appliedExposure == nil)
        #expect(!controls.supportsManualExposure)
    }

    @Test("Reports the clamped applied value, then a camera error without claiming success")
    func exposureResults() async {
        var requests: [Float] = []
        let controls = TrackingComparisonModel(supportsManualExposure: true,
            setExposure: { value in
                requests.append(value)
                if value == -1.3 { return -1 }
                throw ExposureFailure.lockFailed
            }, requestSettings: { _, _ in })
        await controls.applyExposure(-1.3)
        #expect(controls.appliedExposure == -1)
        #expect(controls.exposureError == nil)
        await controls.applyExposure(-0.7)
        #expect(controls.exposureError != nil)
        #expect(controls.appliedExposure == -1)
        #expect(requests == [-1.3, -0.7])
    }

    @Test("Nil from a manual exposure request is unsupported, not a successful adjustment")
    func automaticOnly() async {
        let controls = TrackingComparisonModel(supportsManualExposure: true,
            setExposure: { _ in nil }, requestSettings: { _, _ in })
        await controls.applyExposure(-0.7)
        #expect(!controls.supportsManualExposure)
        #expect(controls.appliedExposure == nil)
        #expect(controls.exposureError != nil)
    }

    @Test("An exposure completion from before camera replacement cannot repopulate state")
    func staleExposure() async {
        let gate = ExposureGate()
        let controls = TrackingComparisonModel(supportsManualExposure: true,
            setExposure: { value in await gate.pause(); return value }, requestSettings: { _, _ in })
        let old = Task { await controls.applyExposure(-1.3) }
        await gate.waitForEntry()
        controls.resetExposure()
        gate.release()
        await old.value
        #expect(controls.appliedExposure == nil)
        #expect(!controls.isApplyingExposure)
        #expect(controls.exposureError == nil)
    }

    @Test("Comparison requests forward all settings to the authoritative owner")
    func settingsRequests() {
        var selected: PanelTrackingMethod?
        var supplied: FeatureTrackingOptions?
        let controls = TrackingComparisonModel(supportsManualExposure: false,
            setExposure: { _ in nil }, requestSettings: { selected = $0; supplied = $1 })
        controls.requestSettings(method: .features,
            options: FeatureTrackingOptions(excludeHighlights: false, normalizeContrast: true))
        #expect(selected == .features)
        #expect(supplied?.excludeHighlights == false)
        #expect(supplied?.normalizeContrast == true)
    }
}

private enum ExposureFailure: Error { case lockFailed }

@MainActor
private final class ExposureGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}
