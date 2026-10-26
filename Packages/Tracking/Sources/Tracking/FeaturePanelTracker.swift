//
//  FeaturePanelTracker.swift
//  Tracking — Tracking / Visual tracking (#82)
//
//  Finds the registered panel in each camera frame by matching its labels and
//  texture with the OpenCV backend (ContourFeatureMatcher), so a covered corner
//  or target doesn't move the result the way it moves a rectangle.
//
//  The backend works on grayscale pixels in its own processing image. This
//  actor owns the backend, prepares upright, downsampled grayscale images for
//  it, and converts its answers back into normalized upright image coordinates
//  with TL/TR/BR/BL identities intact. Every frame is matched against the
//  original reference, so there is no frame-to-frame chain to break.
//

import ContourCore
import ContourFeatureMatcher
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

public actor FeaturePanelTracker: CalibratablePanelTracking {

    /// Upright processing images are at most this many pixels on their longest
    /// side. Bounds matching cost; normalized output doesn't depend on it.
    public static let defaultMaximumDimension = 640

    private struct Session {
        let id: UInt64
        let backend: FeatureBackend
    }

    public let options: FeatureTrackingOptions
    private let maximumDimension: Int
    /// Test seam: runs after an image is prepared, before its result is used.
    private let afterPreparation: (@Sendable () async -> Void)?
    private var session: Session?
    /// Bumped by every start and stop, so work that awaited can tell it's stale.
    private var generation: UInt64 = 0

    public init(options: FeatureTrackingOptions = FeatureTrackingOptions(),
                maximumDimension: Int = FeaturePanelTracker.defaultMaximumDimension) {
        self.init(options: options, maximumDimension: maximumDimension, afterPreparation: nil)
    }

    init(options: FeatureTrackingOptions = FeatureTrackingOptions(),
         maximumDimension: Int = FeaturePanelTracker.defaultMaximumDimension,
         afterPreparation: (@Sendable () async -> Void)?) {
        self.options = options
        self.maximumDimension = max(32, maximumDimension)
        self.afterPreparation = afterPreparation
    }

    /// Register the reference panel. Replaces any current reference, and any
    /// failure leaves nothing registered.
    public func startTracking(_ reference: PanelReference) async throws {
        stopTracking()
        let id = generation

        let quad = reference.detection.quad
        guard PanelHomography.isValid(quad) else { throw PanelTrackingError.invalidReferenceQuad }
        guard let source = CGImageSourceCreateWithData(reference.photo.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PanelTrackingError.unreadableReferencePhoto
        }

        let upright = CIImage(cgImage: image).oriented(Self.orientation(reference.photo.orientation))
        let prepared = await Self.prepare(upright, maximumDimension: maximumDimension)
        await afterPreparation?()
        guard generation == id else { throw PanelTrackingError.superseded }
        guard let prepared else { throw PanelTrackingError.unreadableReferencePhoto }

        guard let backend = FeatureBackend(options: options),
              backend.register(prepared, corners: prepared.pixels(of: quad)) else {
            throw PanelTrackingError.registrationFailed
        }
        session = Session(id: id, backend: backend)
    }

    /// Locate the panel in one camera frame.
    ///
    /// Returns a lost observation, never stale corners, when the panel isn't
    /// found. Throws only for cancellation and for results that no longer
    /// belong to the current reference.
    public func track(_ frame: CameraFrame) async throws -> PanelObservation {
        guard let current = session else { return .lost(.notStarted, at: frame.timestamp) }
        let started = ContinuousClock.now

        let upright = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
        let prepared = await Self.prepare(upright, maximumDimension: maximumDimension)
        await afterPreparation?()
        try Task.checkCancellation()
        // Actor reentrancy: start/stop may have run while the image was prepared.
        guard session?.id == current.id else { throw PanelTrackingError.superseded }

        guard let prepared else {
            var lost = PanelObservation.lost(.trackerFailed, at: frame.timestamp)
            lost.featureDiagnostics = Self.diagnostics(nil, inliers: [], message: "Frame could not be prepared",
                                                       since: started)
            return lost
        }

        let match = current.backend.match(prepared)
        let inliers = match.inliers.map(prepared.normalized)
        var observation: PanelObservation
        switch match.status {
        case CFT_STATUS_OK:
            let corners = match.corners.map(prepared.normalized)
            let quad = PanelQuad(topLeft: corners[0], topRight: corners[1],
                                 bottomRight: corners[2], bottomLeft: corners[3])
            if PanelHomography.isValid(quad) {
                observation = .tracked(quad, confidence: Double(match.result.confidence), at: frame.timestamp)
            } else {
                observation = .lost(.invalidGeometry, at: frame.timestamp)
            }
        case CFT_STATUS_LOST:
            observation = .lost(Self.lossReason(match.result.lossReason), at: frame.timestamp)
        case CFT_STATUS_NOT_REGISTERED:
            observation = .lost(.notStarted, at: frame.timestamp)
        default:
            observation = .lost(.trackerFailed, at: frame.timestamp)
        }
        let message = match.status == CFT_STATUS_LOST
            ? String(cString: cft_loss_reason_description(match.result.lossReason))
            : String(cString: cft_status_description(match.status))
        observation.featureDiagnostics = Self.diagnostics(match.status == CFT_STATUS_OK || match.status == CFT_STATUS_LOST
                                                          ? match.result : nil,
                                                          inliers: inliers, message: message, since: started)
        return observation
    }

    /// Drop the reference and its backend. Idempotent and never suspends.
    public func stopTracking() {
        generation &+= 1
        session = nil
    }

    // MARK: Calibration — forwarded; the hybrid coordinator decides which views count.

    /// Count the most recent tracked frame as an accepted calibration view.
    /// Lost frames and repeated calls for the same frame don't count.
    public func observeCalibrationView() {
        session?.backend.observeCalibrationView()
    }

    /// Select the original features that persisted across accepted views
    /// (#84). Returns how many are now matched against, or nil when there's too
    /// little evidence, count or panel coverage, in which case every original
    /// feature is used.
    public func finishCalibration() -> Int? {
        session?.backend.finishCalibration()
    }

    /// Forget the counts and match against every original feature again.
    public func resetCalibration() {
        session?.backend.resetCalibration()
    }

    // MARK: - Conversion

    static func lossReason(_ reason: CFTLossReason) -> PanelObservation.LossReason {
        switch reason {
        case CFT_LOSS_LOW_INLIER_RATIO, CFT_LOSS_LOW_COVERAGE: .lowConfidence
        case CFT_LOSS_INVALID_GEOMETRY, CFT_LOSS_IMPLAUSIBLE_AREA: .invalidGeometry
        default: .notFound
        }
    }

    private static func diagnostics(_ result: CFTMatchResult?, inliers: [ImagePoint], message: String,
                                    since started: ContinuousClock.Instant) -> FeatureTrackingDiagnostics {
        let elapsed = ContinuousClock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let fitted = result.map { $0.inlierCount > 0 } ?? false
        return FeatureTrackingDiagnostics(
            referenceFeatures: Int(result?.referenceFeatures ?? 0),
            frameFeatures: Int(result?.frameFeatures ?? 0),
            matchCount: Int(result?.matchCount ?? 0),
            inlierCount: Int(result?.inlierCount ?? 0),
            coverage: Double(result?.coverage ?? 0),
            reprojectionError: fitted ? Double(result!.reprojectionError) : .infinity,
            processingMilliseconds: milliseconds,
            message: message,
            inlierPoints: inliers,
            saturatedFraction: Double(result?.saturatedFraction ?? 0),
            excludedHighlightFraction: Double(result?.excludedHighlightFraction ?? 0))
    }

    private static func orientation(_ orientation: PhotoOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }

    // MARK: - Preparation

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `image` upright, as 8-bit grayscale no larger than `maximumDimension`
    /// on its longest side. Runs off the actor.
    @concurrent
    static func prepare(_ image: CIImage, maximumDimension: Int) async -> PreparedImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = min(1, CGFloat(maximumDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))

        var upright = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if width != Int(extent.width) || height != Int(extent.height) {
            let scaleY = CGFloat(height) / extent.height
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(upright.clampedToExtent(), forKey: kCIInputImageKey)
            filter?.setValue(scaleY, forKey: kCIInputScaleKey)
            filter?.setValue((CGFloat(width) / extent.width) / scaleY, forKey: kCIInputAspectRatioKey)
            guard let scaled = filter?.outputImage else { return nil }
            upright = scaled
        }

        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(upright, toBitmap: buffer.baseAddress!, rowBytes: width,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return PreparedImage(pixels: pixels, width: width, height: height)
    }
}

/// Tightly packed upright grayscale pixels handed to the backend.
struct PreparedImage: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    /// Normalized upright point → backend pixel coordinates (pixel centers at
    /// integers, so normalized 0 and 1 are the outer pixel edges).
    func pixel(_ point: ImagePoint) -> CFTPoint {
        CFTPoint(x: Float(point.x * Double(width) - 0.5), y: Float(point.y * Double(height) - 0.5))
    }

    func pixels(of quad: PanelQuad) -> [CFTPoint] {
        [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map(pixel)
    }

    func normalized(_ point: CFTPoint) -> ImagePoint {
        ImagePoint(x: (Double(point.x) + 0.5) / Double(width), y: (Double(point.y) + 0.5) / Double(height))
    }

    func withImage<T>(_ body: (UnsafePointer<CFTGrayImage>) -> T) -> T {
        // The pixels stay alive for the whole call; the backend never keeps them.
        pixels.withUnsafeBufferPointer { buffer in
            var image = CFTGrayImage(pixels: buffer.baseAddress, width: Int32(width), height: Int32(height),
                                     bytesPerRow: Int32(width))
            return body(&image)
        }
    }
}

/// Owns one backend tracker. Only ever touched from its FeaturePanelTracker.
final class FeatureBackend {
    struct Match {
        let status: CFTStatus
        let result: CFTMatchResult
        let corners: [CFTPoint]
        let inliers: [CFTPoint]
    }

    private let handle: OpaquePointer

    init?(options: FeatureTrackingOptions) {
        var config = CFTConfig()
        cft_default_config(&config)
        // The same extraction policy for the reference and every frame (#83).
        config.excludeHighlights = options.excludeHighlights ? 1 : 0
        config.normalizeContrast = options.normalizeContrast ? 1 : 0
        guard let handle = cft_create(&config) else { return nil }
        self.handle = handle
    }

    deinit { cft_destroy(handle) }

    func register(_ image: PreparedImage, corners: [CFTPoint]) -> Bool {
        image.withImage { cft_register_reference(handle, $0, corners, nil) } == CFT_STATUS_OK
    }

    func match(_ image: PreparedImage) -> Match {
        var result = CFTMatchResult()
        let status = image.withImage { cft_match_frame(handle, $0, &result) }
        let count = Int(cft_copy_inlier_points(handle, nil, 0))
        var inliers = [CFTPoint](repeating: CFTPoint(), count: count)
        if count > 0 { cft_copy_inlier_points(handle, &inliers, Int32(count)) }
        let corners = [result.corners.0, result.corners.1, result.corners.2, result.corners.3]
        return Match(status: status, result: result, corners: corners, inliers: inliers)
    }

    func observeCalibrationView() {
        _ = cft_observe_calibration_view(handle)
    }

    func finishCalibration() -> Int? {
        let count = cft_finish_calibration(handle)
        return count >= 0 ? Int(count) : nil
    }

    func resetCalibration() {
        cft_reset_calibration(handle)
    }
}
