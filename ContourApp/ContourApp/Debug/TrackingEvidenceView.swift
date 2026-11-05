#if DEBUG
import SwiftUI
import Tracking

struct TrackingEvidenceView: View {
    let evidence: TrackingEvidence

    private var sourceColor: Color {
        switch evidence.source {
        case .visual: .blue
        case .fused: .green
        case .world: .orange
        case .unavailable, nil: .secondary
        }
    }

    var body: some View {
        GroupBox("Tracking evidence") {
            VStack(alignment: .leading, spacing: 10) {
                Label(evidence.source?.rawValue ?? "Source unavailable", systemImage: "scope")
                    .font(.headline)
                    .foregroundStyle(sourceColor)
                Text("Source describes this image’s returned alignment. Calibration readiness is separate.")
                    .font(.caption).foregroundStyle(.secondary)
                rows(Array(evidence.calibration.prefix(2)))
                ForEach(Array(evidence.explanations.enumerated()), id: \.offset) { _, explanation in
                    Text(explanation).font(.caption)
                }
                DisclosureGroup("Calibration and recovery") { rows(Array(evidence.calibration.dropFirst(2))) }
                DisclosureGroup("Feature matching and highlights") { rows(evidence.features) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rows(_ values: [TrackingEvidence.Row]) -> some View {
        ForEach(values) { row in
            LabeledContent(row.label, value: row.value)
                .font(.caption).monospacedDigit()
        }
    }
}
#endif
