#if DEBUG
import Foundation
import Observation
import Tracking

/// Requests configuration changes; Guidance remains the settings owner.
@MainActor @Observable
final class TrackingComparisonModel {
    private(set) var supportsManualExposure: Bool
    private(set) var appliedExposure: Float?
    private(set) var exposureError: String?
    private(set) var isApplyingExposure = false
    private(set) var automaticExposureConfirmed = false
    private let initialExposureSupport: Bool
    private let setExposure: @MainActor (Float) async throws -> Float?
    private let settingsRequest: @MainActor (PanelTrackingMethod, FeatureTrackingOptions) -> Void
    private var exposureGeneration: UInt64 = 0

    init(supportsManualExposure: Bool,
         setExposure: @escaping @MainActor (Float) async throws -> Float?,
         requestSettings: @escaping @MainActor (PanelTrackingMethod, FeatureTrackingOptions) -> Void) {
        self.supportsManualExposure = supportsManualExposure
        initialExposureSupport = supportsManualExposure
        self.setExposure = setExposure
        settingsRequest = requestSettings
    }

    func requestSettings(method: PanelTrackingMethod, options: FeatureTrackingOptions) {
        settingsRequest(method, options)
    }

    func applyExposure(_ value: Float) async {
        guard supportsManualExposure, !isApplyingExposure, value.isFinite else { return }
        exposureGeneration &+= 1
        let generation = exposureGeneration
        isApplyingExposure = true
        exposureError = nil
        defer {
            if generation == exposureGeneration { isApplyingExposure = false }
        }
        do {
            let applied = try await setExposure(value)
            guard generation == exposureGeneration, !Task.isCancelled else { return }
            if let applied, applied.isFinite {
                appliedExposure = applied
                automaticExposureConfirmed = false
            } else if value == 0, applied == nil {
                appliedExposure = nil
                automaticExposureConfirmed = true
            } else {
                supportsManualExposure = false
                exposureError = "Manual exposure adjustment is unavailable on this camera."
            }
        } catch {
            guard generation == exposureGeneration, !Task.isCancelled else { return }
            exposureError = error.localizedDescription
        }
    }

    /// A camera restart invalidates both applied-value claims and delayed completions.
    func resetExposure() {
        exposureGeneration &+= 1
        appliedExposure = nil
        automaticExposureConfirmed = false
        exposureError = nil
        isApplyingExposure = false
        supportsManualExposure = initialExposureSupport
    }
}
#endif
