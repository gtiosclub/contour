#if DEBUG
import ContourCore
import ContourFeedback
import CoreGraphics
import SwiftUI
import Tracking

/// Same-photo comparison only. Never replaces the live pipeline or registers Tracking.
@MainActor
struct MLCapturedPanelReviewView: View {
    let photo: PanelPhoto
    @Environment(\.scenePhase) private var scenePhase
    @State private var detector = MLButtonDetection()
    @State private var refreshID = UUID()
    @State private var threshold: Float = 0.1
    @State private var mode: MLButtonDetection.InferenceMode = .wholeImageAndTiles
    @State private var refinesGeometry = true
    @State private var layer: MLReviewLayer = .final
    @State private var completedRequest: RequestKey?
    @State private var state: AnalysisState = .idle

    private struct RequestKey: Equatable, Hashable {
        var photoID: UUID
        var refreshID: UUID
        var threshold: Float
        var mode: MLButtonDetection.InferenceMode
        var refinesGeometry: Bool
    }
    private struct WorkID: Equatable {
        var request: RequestKey
        var active: Bool
    }
    private enum AnalysisState {
        case idle
        case loading
        case success(RequestKey, MLButtonDetection.Review)
        case failure(RequestKey, String)
    }

    var body: some View {
        let key = RequestKey(photoID: photo.id, refreshID: refreshID, threshold: threshold, mode: mode, refinesGeometry: refinesGeometry)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Confidence threshold", selection: $threshold) {
                Text("0.10").tag(Float(0.1))
                Text("0.15").tag(Float(0.15))
                Text("0.25").tag(Float(0.25))
                Text("0.50").tag(Float(0.5))
            }.pickerStyle(.segmented)
            Picker("Detection mode", selection: $mode) {
                Text("Whole image").tag(MLButtonDetection.InferenceMode.wholeImage)
                Text("Whole + crops").tag(MLButtonDetection.InferenceMode.wholeImageAndTiles)
            }.pickerStyle(.segmented)
            Toggle("Edge refinement and isolated-noise filtering", isOn: $refinesGeometry)
            Picker("Detection stage", selection: $layer) {
                ForEach(MLReviewLayer.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch state {
            case .success(let resultKey, let review) where resultKey == key:
                MLReviewImage(photo: photo, review: review, layer: layer)
                Text("Same captured photo. Yellow: estimated region, not registered with Tracking. Cyan: accepted controls. Orange: filtered raw candidates. Numbers identify the rows below.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(review.raw.count) raw · \(review.raw.filter(\.accepted).count) eligible · \(review.merged.count) merged · \(review.refined.count) refined · \(review.detection?.map.buttons.count ?? 0) final")
                    .font(.caption).monospacedDigit()
                Text(String(format: "%d inference passes · %.2f seconds · threshold %.2f", review.inferenceCount, review.elapsedSeconds, Double(threshold)))
                    .font(.caption).foregroundStyle(.secondary)
                if let floor = review.modelConfidenceFloor {
                    Text("Model score floor: \(floor, format: .number.precision(.fractionLength(2))) · runtime override")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Score = object confidence × class confidence (not a calibrated accuracy). Raw shows Vision output after model filtering. Merged preserves ML boxes. Refined matches unambiguous edges and removes isolated weak detections. Final drops conflicting lower-score boxes; boxes are never squeezed.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(review.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                if let error = review.selectionError {
                    Text(Self.message(for: error)).font(.caption).foregroundStyle(.red)
                }
                DisclosureGroup("Scores and labels (\(layer.rawValue))") {
                    ForEach(Array(MLReviewBox.boxes(review, layer: layer).enumerated()), id: \.offset) { index, box in
                        Text("\(index + 1). \(box.label) · \(box.confidence, format: .number.precision(.fractionLength(3))) · \(box.source)")
                            .font(.caption).foregroundStyle(box.accepted ? Color.primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let detail = box.scoreDetail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Button("Run again") { refreshID = UUID() }.disabled(scenePhase != .active)
            case .failure(let resultKey, let message) where resultKey == key:
                Text(message).foregroundStyle(.red)
                Button("Retry ML detection") { refreshID = UUID() }.disabled(scenePhase != .active)
            default:
                if scenePhase == .active {
                    ProgressView("Detecting ML controls and reading labels…")
                } else {
                    Text("ML analysis resumes when the app is active.").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: WorkID(request: key, active: scenePhase == .active)) {
            guard scenePhase == .active else {
                if case .loading = state { state = .idle }
                return
            }
            guard completedRequest != key else { return }
            state = .loading
            do {
                // Avoid starting multiple expensive scans while toggling settings.
                try await Task.sleep(for: .milliseconds(250))
                let review = try await detector.review(from: photo, minimumConfidence: threshold, mode: mode, refinesGeometry: refinesGeometry)
                try Task.checkCancellation()
                state = .success(key, review)
                completedRequest = key
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      (error as? SurfaceUnderstandingError) != .cancelled else { return }
                state = .failure(key, Self.message(for: error))
                completedRequest = key
            }
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case SurfaceUnderstandingError.noPanelFound:
            "ML could not select a clear group of at least two non-conflicting controls. Inspect Raw and Merged to see what was removed."
        case SurfaceUnderstandingError.undecodableImage:
            "ML could not read the captured photo."
        case SurfaceUnderstandingError.underlying(let reason):
            "ML detection failed: \(reason)"
        default:
            "ML detection failed: \(error.localizedDescription)"
        }
    }
}

private enum MLReviewLayer: String, CaseIterable {
    case raw = "Raw"
    case merged = "Merged"
    case refined = "Refined"
    case final = "Final"
}

private struct MLReviewBox {
    var corners: [ImagePoint]
    var label: String
    var confidence: Double
    var source: String
    var accepted: Bool
    var scoreDetail: String? = nil

    static func boxes(_ review: MLButtonDetection.Review, layer: MLReviewLayer) -> [Self] {
        func corners(_ r: PanelRect) -> [ImagePoint] {
            [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY),
             .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)]
        }
        if layer != .final {
            return (layer == .raw ? review.raw : layer == .merged ? review.merged : review.refined).map {
                Self(corners: corners($0.bounds), label: $0.category, confidence: $0.confidence,
                     source: $0.source + ($0.rejectionReason.map { " · " + $0 } ?? ""), accepted: $0.accepted,
                     scoreDetail: String(format: "Object %.3f × class %.3f = %.3f", $0.objectConfidence, $0.classificationConfidence, $0.confidence))
            }
        }
        guard let detection = review.detection,
              let projection = try? PanelHomography(quad: detection.quad) else { return [] }
        return detection.map.buttons.map { button in
            let points = corners(button.bounds).compactMap {
                projection.imagePoint(for: PanelPoint(x: $0.x, y: $0.y))
            }
            return Self(corners: points, label: button.label ?? "Unlabelled", confidence: button.confidence,
                        source: "Final + OCR", accepted: true)
        }
    }
}

/// Local overlay keeps the shared TrackingImageView and original debug image unchanged.
@MainActor
private struct MLReviewImage: View {
    let photo: PanelPhoto
    let review: MLButtonDetection.Review
    let layer: MLReviewLayer
    @State private var image: CGImage?
    @State private var finishedPhotoID: UUID?
    private let renderer = FrameImageRenderer()

    var body: some View {
        Group {
            if let image, finishedPhotoID == photo.id {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        Canvas { context, size in
                            func point(_ p: ImagePoint) -> CGPoint {
                                CGPoint(x: p.x * size.width, y: p.y * size.height)
                            }
                            func polygon(_ corners: [ImagePoint]) -> Path {
                                var path = Path()
                                for (index, p) in corners.enumerated() {
                                    if index == 0 { path.move(to: point(p)) }
                                    else { path.addLine(to: point(p)) }
                                }
                                path.closeSubpath()
                                return path
                            }
                            if let quad = review.detection?.quad {
                                context.stroke(polygon([quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]),
                                               with: .color(.yellow), lineWidth: 2)
                            }
                            for (index, box) in MLReviewBox.boxes(review, layer: layer).enumerated() {
                                guard box.corners.count == 4, let anchor = box.corners.first else { continue }
                                let color: Color = box.accepted ? .cyan : .orange
                                context.stroke(polygon(box.corners), with: .color(color), lineWidth: 1.5)
                                context.draw(Text("\(index + 1) · \(box.confidence, format: .number.precision(.fractionLength(3)))")
                                    .font(.caption2).foregroundColor(color), at: point(anchor), anchor: .topLeading)
                            }
                        }.allowsHitTesting(false)
                    }
            } else if finishedPhotoID == photo.id {
                Text("Captured image unavailable.").foregroundStyle(.secondary)
            } else {
                ProgressView("Loading captured photo…")
            }
        }
        .task(id: photo.id) {
            let rendered = await renderer.image(for: photo)
            guard !Task.isCancelled else { return }
            image = rendered
            finishedPhotoID = photo.id
        }
    }
}
#endif
