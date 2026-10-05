// Tracking — Panel Registration & Lost Tracking (Vision boundary)
import ContourCore
import CoreGraphics
import ImageIO
import Vision

/// Vision's raw corners before validation: normalized to the upright image,
/// lower-left origin, y up.
struct VisionQuad: Sendable {
    let topLeft: SIMD2<Double>
    let topRight: SIMD2<Double>
    let bottomRight: SIMD2<Double>
    let bottomLeft: SIMD2<Double>
    let confidence: Double
}

/// What a tracking update runs on. Pixels are read-only throughout.
/// Sendable so the pixels can be handed to Vision, which runs off this actor.
enum TrackerImage: Sendable {
    case still(CGImage, CGImagePropertyOrientation)
    case frame(CameraFrame)
}

/// One stateful tracking sequence. Owned by a single `PanelTracker` session and
/// never shared: each update continues from the previous one.
protocol RectangleTracking: AnyObject {
    nonisolated(nonsending) func update(_ image: TrackerImage) async throws -> VisionQuad?
}

final class VisionRectangleTracker: RectangleTracking {
    private let request: TrackRectangleRequest

    /// `start` is in upright image space (y down); Vision wants y up.
    init(start: PanelQuad) {
        func point(_ p: ImagePoint) -> NormalizedPoint { NormalizedPoint(x: p.x, y: 1 - p.y) }
        let observation = RectangleObservation(
            topLeft: point(start.topLeft), topRight: point(start.topRight),
            bottomRight: point(start.bottomRight), bottomLeft: point(start.bottomLeft))
        request = TrackRectangleRequest(detectedRectangle: observation)
        request.trackingLevel = .accurate
    }

    nonisolated(nonsending) func update(_ image: TrackerImage) async throws -> VisionQuad? {
        let result: RectangleObservation?
        switch image {
        case let .still(cgImage, orientation):
            result = try await request.perform(on: cgImage, orientation: orientation)
        case let .frame(frame):
            result = try await request.perform(on: frame.pixelBuffer, orientation: frame.orientation)
        }
        guard let result else { return nil }
        func point(_ p: NormalizedPoint) -> SIMD2<Double> { SIMD2(Double(p.x), Double(p.y)) }
        return VisionQuad(topLeft: point(result.topLeft), topRight: point(result.topRight),
                          bottomRight: point(result.bottomRight), bottomLeft: point(result.bottomLeft),
                          confidence: Double(result.confidence))
    }
}
