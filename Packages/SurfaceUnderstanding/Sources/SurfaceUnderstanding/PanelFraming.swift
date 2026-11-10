import ContourCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Fast aiming advice before a scan. Speech and camera scheduling belong to the app.
public struct PanelFraming: Sendable {
    public enum Direction: Hashable, Sendable {
        case left, right, up, down
    }

    public enum Advice: Hashable, Sendable {
        case noPanel, moveCloser, moveBack, tooAngled, ready
        /// The direction to move the phone, in the upright image.
        case offCenter(Direction)

        public var spoken: String {
            switch self {
            case .noPanel: "I can't see the panel"
            case .moveCloser: "Move closer"
            case .moveBack: "Move back a little"
            case .tooAngled: "Point the phone straight at the panel"
            case .ready: "Hold still"
            case .offCenter(.left): "Move left a little"
            case .offCenter(.right): "Move right a little"
            case .offCenter(.up): "Move up a little"
            case .offCenter(.down): "Move down a little"
            }
        }
    }

    public init() {}

    /// A live frame in the camera's native pixels. Mirrored inputs are unsupported.
    public func advice(for pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) async -> Advice {
        let photoOrientation: PhotoOrientation
        switch orientation {
        case .up: photoOrientation = .up
        case .right: photoOrientation = .right
        case .down: photoOrientation = .down
        case .left: photoOrientation = .left
        default: return .noPanel
        }
        guard !Task.isCancelled else { return .noPanel }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image) == 0,
              let image else { return .noPanel }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil
        ) else { return .noPanel }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return .noPanel }
        let photo = PanelPhoto(data: data as Data,
                               pixelSize: PixelSize(width: image.width, height: image.height),
                               orientation: photoOrientation, timestamp: .now)
        return await advice(for: photo)
    }

    /// Detect the panel without OCR, then decide in upright image coordinates.
    public func advice(for photo: PanelPhoto) async -> Advice {
        do {
            let result = try await PanelDetector().detectPanel(in: photo)
            let frame: PixelSize
            switch photo.orientation {
            case .up, .down: frame = photo.pixelSize
            case .left, .right:
                frame = PixelSize(width: photo.pixelSize.height, height: photo.pixelSize.width)
            }
            return advice(for: result.quad, frame: frame)
        } catch {
            return .noPanel
        }
    }

    /// Pure geometry. The quad and frame dimensions both describe the upright image.
    func advice(for quad: PanelQuad?, frame: PixelSize) -> Advice {
        guard let quad, frame.width > 0, frame.height > 0 else { return .noPanel }
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .noPanel }
        if quad == .fullFrame { return .moveBack }

        let left = corners.map(\.x).min()!, right = corners.map(\.x).max()!
        let top = corners.map(\.y).min()!, bottom = corners.map(\.y).max()!
        let clippedLeft = left <= 0.01, clippedRight = right >= 0.99
        let clippedTop = top <= 0.01, clippedBottom = bottom >= 0.99
        if (clippedLeft && clippedRight) || (clippedTop && clippedBottom) { return .moveBack }
        // For adjacent clipped edges, choose the greater overshoot. Ties use
        // horizontal advice first to keep the result deterministic.
        var clipped: (direction: Direction, amount: Double)?
        for (direction, hit, amount): (Direction, Bool, Double) in [
            (.left, clippedLeft, 0.01 - left), (.right, clippedRight, right - 0.99),
            (.up, clippedTop, 0.01 - top), (.down, clippedBottom, bottom - 0.99)
        ] where hit {
            if clipped == nil || amount > clipped!.amount { clipped = (direction, amount) }
        }
        if let clipped { return .offCenter(clipped.direction) }

        let dx = corners.map(\.x).reduce(0, +) / 4 - 0.5
        let dy = corners.map(\.y).reduce(0, +) / 4 - 0.5
        if abs(dx) > 0.15 || abs(dy) > 0.15 {
            if abs(dx) >= abs(dy) { return .offCenter(dx < 0 ? .left : .right) }
            return .offCenter(dy < 0 ? .up : .down)
        }

        func distance(_ a: ImagePoint, _ b: ImagePoint) -> Double {
            hypot((a.x - b.x) * Double(frame.width), (a.y - b.y) * Double(frame.height))
        }
        let topEdge = distance(quad.topLeft, quad.topRight)
        let bottomEdge = distance(quad.bottomLeft, quad.bottomRight)
        let leftEdge = distance(quad.topLeft, quad.bottomLeft)
        let rightEdge = distance(quad.topRight, quad.bottomRight)
        guard min(topEdge, bottomEdge, leftEdge, rightEdge) > 0 else { return .noPanel }
        if min(topEdge, bottomEdge) < 0.7 * max(topEdge, bottomEdge) ||
            min(leftEdge, rightEdge) < 0.7 * max(leftEdge, rightEdge) {
            return .tooAngled
        }
        if right - left < 0.6 && bottom - top < 0.65 { return .moveCloser }
        return .ready
    }

    /// Retained by the app between frames. Uses capture timestamps, never sleeps.
    public struct Stable: Sendable {
        private var lastRecord: Date?
        private var readySince: Date?

        public init() {}

        public func isDue(at time: Date) -> Bool {
            guard let lastRecord else { return true }
            return time.timeIntervalSince(lastRecord) >= 0.5
        }

        /// True after a consecutive sequence of ready observations spans one second.
        /// Repeated timestamps cannot advance the hold; a reversed clock restarts it.
        public mutating func record(_ advice: Advice, at time: Date) -> Bool {
            if let lastRecord, time < lastRecord { readySince = nil }
            lastRecord = time
            guard advice == .ready else {
                readySince = nil
                return false
            }
            if readySince == nil { readySince = time }
            return time.timeIntervalSince(readySince!) >= 1
        }
    }
}
