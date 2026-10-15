import Foundation
import Observation
import SwiftUI
import Tracking

/// Readable evidence for the guidance screen. The source describes the actual
/// output in use; calibration readiness is a separate piece of information.
struct GuidanceStatusSnapshot: Equatable {
    let source: String
    let calibration: String
    let verification: String
    let message: String

    static let waiting = GuidanceStatusSnapshot(
        source: "Waiting for tracking",
        calibration: "Calibration: unavailable",
        verification: "Last visual check: unavailable",
        message: "Tracking evidence is not available yet."
    )

    init(source: String, calibration: String, verification: String, message: String) {
        self.source = source
        self.calibration = calibration
        self.verification = verification
        self.message = message
    }

    init(diagnostics: HybridTrackingDiagnostics?, error: String? = nil) {
        if let error, !error.isEmpty {
            self = Self(source: "Tracking unavailable", calibration: "Calibration: unavailable",
                        verification: "Last visual check: unavailable", message: error)
            return
        }
        guard let diagnostics else {
            self = .waiting
            return
        }

        source = diagnostics.source.rawValue
        calibration = diagnostics.calibrationReady
            ? "Calibration ready"
            : "Calibration samples: \(diagnostics.calibrationFrames)"
        if let age = diagnostics.visualVerificationAge, age.isFinite, age >= 0 {
            verification = "Last visual check: \(age.formatted(.number.precision(.fractionLength(1)))) s ago"
        } else {
            verification = "Last visual check: unavailable"
        }
        message = diagnostics.message.isEmpty ? diagnostics.mode.rawValue : diagnostics.message
    }
}

/// The frame loop can offer every status without waiting for UI publication.
/// The display owner calls `publishIfDue` from a slower tick (at most 10 Hz).
/// This keeps the newest evidence and avoids publishing unchanged snapshots.
@MainActor
@Observable
final class GuidanceStatusDisplay {
    private(set) var current: GuidanceStatusSnapshot = .waiting
    @ObservationIgnored private var pending: GuidanceStatusSnapshot?
    @ObservationIgnored private var lastPublication: ContinuousClock.Instant?
    @ObservationIgnored private let minimumInterval: Duration = .milliseconds(100)

    func receive(_ snapshot: GuidanceStatusSnapshot) {
        pending = snapshot
    }

    func publishIfDue(at now: ContinuousClock.Instant = .now) {
        guard let pending else { return }
        guard lastPublication.map({ $0.duration(to: now) >= minimumInterval }) ?? true else { return }
        self.pending = nil
        guard pending != current else { return }
        current = pending
        lastPublication = now
    }

    /// Stop/replacement must discard unpublished evidence as well as the
    /// currently visible status before the next session begins.
    func reset() {
        pending = nil
        lastPublication = nil
        current = .waiting
    }
}

/// A single persistent row. It does not insert/remove subrows as the source
/// changes, and text remains readable when Dynamic Type needs more lines.
struct GuidanceStatusRow: View {
    let snapshot: GuidanceStatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Tracking", value: snapshot.source)
                .font(.headline)
            Text(snapshot.calibration)
            Text(snapshot.verification)
            Text(snapshot.message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    List {
        Section("Tracking status") {
            GuidanceStatusRow(snapshot: .waiting)
        }
    }
}
