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

    static let stopped = GuidanceStatusSnapshot(
        source: "No active guidance", calibration: "Calibration: unavailable",
        verification: "Last visual check: unavailable", message: "Start guidance to receive current tracking status."
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
        let fallback = diagnostics.source == .unavailable
            ? "No usable alignment is available for guidance." : diagnostics.mode.rawValue
        let explanation = diagnostics.message.isEmpty ? fallback : diagnostics.message
        let blocker: String?
        switch diagnostics.repositionReason {
        case .suspectedGlare: blocker = "Possible glare is blocking a visual check."
        case .weakAlignment: blocker = "Visual alignment is too weak to verify."
        case nil: blocker = nil
        }
        message = [explanation, blocker].compactMap { $0 }.joined(separator: " ")
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

    /// A separate monotonic display loop. It never sleeps in the frame/feedback
    /// path, and a final pending sample is published even if no new frame arrives.
    func run() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            publishIfDue(at: clock.now)
            do { try await clock.sleep(for: minimumInterval) }
            catch { return }
        }
    }

    /// Stop/replacement must discard unpublished evidence as well as the
    /// currently visible status before the next session begins.
    func reset(to snapshot: GuidanceStatusSnapshot = .waiting) {
        pending = nil
        lastPublication = nil
        current = snapshot
    }
}

/// Reserve a font-scaled viewport so ordinary evidence changes cannot move
/// controls below it. Long messages remain available by scrolling, including
/// at accessibility text sizes; no status fields are conditionally inserted.
struct GuidanceStatusRow: View {
    let snapshot: GuidanceStatusSnapshot
    @ScaledMetric(relativeTo: .body) private var viewportHeight: CGFloat = 180

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tracking: \(snapshot.source)")
                    .font(.headline)
                GuidanceStatusDetails(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: viewportHeight)
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("guidance-status")
    }
}

#Preview {
    List {
        Section("Tracking status") {
            GuidanceStatusRow(snapshot: .waiting)
        }
    }
}

/// Set a semantic font explicitly so container styling cannot fix the text size.
struct GuidanceStatusDetails: View {
    let snapshot: GuidanceStatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.calibration)
            Text(snapshot.verification)
            Text(snapshot.message)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }
}
