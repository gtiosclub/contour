#if DEBUG
import Foundation
import Tracking

/// A presentation value made only from the sample paired with the displayed image.
struct TrackingEvidence {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let source: HybridTrackingDiagnostics.Source?
    let calibration: [Row]
    let features: [Row]
    let explanations: [String]

    init(sample: LiveTrackingSample?) {
        let hybrid = sample?.hybridDiagnostics
        let feature = sample?.featureDiagnostics
        if let sample, sample.panelQuad == nil {
            source = .unavailable
        } else {
            // Missing diagnostics cannot establish which algorithm supplied geometry.
            source = hybrid?.source
        }
        calibration = [
            Row(label: "Mode", value: hybrid?.mode.rawValue ?? "Unavailable"),
            Row(label: "Readiness", value: hybrid.map { $0.calibrationReady ? "Ready" : "Not ready" } ?? "Unavailable"),
            Row(label: "Calibration samples", value: Self.count(hybrid?.calibrationFrames)),
            Row(label: "Stable features", value: Self.count(hybrid?.stableFeatures)),
            Row(label: "Baseline", value: Self.measurement(hybrid?.baselineCentimeters, unit: "cm")),
            Row(label: "Alignment error", value: Self.measurement(hybrid?.alignmentError, unit: "image units", precision: 3)),
            Row(label: "Corner error", value: Self.measurement(hybrid?.cornerError, unit: "image units", precision: 3)),
            Row(label: "Resets", value: Self.count(hybrid?.resetCount)),
            Row(label: "Reset reason", value: Self.text(hybrid?.lastResetReason)),
            Row(label: "Last visual verification", value: Self.measurement(hybrid?.visualVerificationAge, unit: "s ago"))
        ]
        features = [
            Row(label: "Reference features", value: Self.count(feature?.referenceFeatures)),
            Row(label: "Frame features", value: Self.count(feature?.frameFeatures)),
            Row(label: "Matches", value: Self.count(feature?.matchCount)),
            Row(label: "Inliers", value: Self.count(feature?.inlierCount)),
            Row(label: "Coverage", value: Self.fraction(feature?.coverage)),
            Row(label: "Reprojection error", value: Self.measurement(feature?.reprojectionError, unit: "processing px")),
            Row(label: "Feature processing", value: Self.measurement(feature?.processingMilliseconds, unit: "ms")),
            Row(label: "Saturated highlights", value: Self.fraction(feature?.saturatedFraction)),
            Row(label: "Excluded highlights", value: Self.fraction(feature?.excludedHighlightFraction))
        ]
        var messages = [hybrid?.message, feature?.message].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch hybrid?.repositionReason {
        case .suspectedGlare:
            messages.append("Possible glare is a heuristic signal, not proof of reflection removal. Try a different angle or supported exposure preset.")
        case .weakAlignment:
            messages.append("Visual alignment is too weak to verify. Try clearer texture or a different view.")
        case nil: break
        }
        explanations = messages
    }

    private static func count(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "Unavailable" }
        return String(value)
    }

    private static func text(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unavailable" }
        return value
    }

    private static func measurement(_ value: Double?, unit: String, precision: Int = 2) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        return String(format: "%.*f %@", locale: Locale(identifier: "en_US_POSIX"), precision, value, unit)
    }

    private static func fraction(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...1).contains(value) else { return "Unavailable" }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }
}
#endif
