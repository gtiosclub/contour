//
//  PanelTracker.swift
//  Tracking — Tracking / Panel Registration & Lost Tracking
//
//  Weeks 2–3 deliverable: "Track the panel as the phone moves."
//
//  The user is holding a phone they cannot see, pointed at an appliance they
//  cannot see, while reaching toward it with the other hand. The panel will
//  leave the frame. Losing it is normal; the job is to notice quickly, say so
//  honestly, and recover.
//
//  Output is the panel's four corners in image space (`PanelQuad`), per frame.
//  `PanelHomography` turns those into panel space. Metric 3D pose is out of
//  scope for issue #8, so `currentPose()` asserts nothing yet.
//

import ContourCore
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// One frame's panel location, in the full upright image — not panel space.
/// A lost observation never carries corners from an earlier frame.
public struct PanelObservation: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case tracked
        case lost(LossReason)
    }

    public enum LossReason: String, Hashable, Sendable {
        /// No reference has been registered, or tracking was stopped.
        case notStarted
        /// Vision returned no rectangle for this frame.
        case notFound
        /// A rectangle came back, but below the confidence floor.
        case lowConfidence
        /// The corners don't form a usable panel (folded, collinear, tiny).
        case invalidGeometry
        /// Vision's tracking sequence errored on this frame, which is what it
        /// does when something covers a corner. The next frame starts a fresh
        /// sequence from the last good position.
        case trackerFailed
        /// A restarted sequence found a rectangle, but it doesn't look like
        /// the panel (a cabinet, a door).
        case unrecognized
    }

    /// The camera frame's capture time, not when processing finished.
    public let timestamp: Date
    /// TL/TR/BR/BL keep their logical identities. `nil` exactly when lost.
    public let quad: PanelQuad?
    /// `0...1`; `0` when lost.
    public let confidence: Double
    public let status: Status

    public static func tracked(_ quad: PanelQuad, confidence: Double, at timestamp: Date) -> Self {
        Self(timestamp: timestamp, quad: quad, confidence: confidence, status: .tracked)
    }

    public static func lost(_ reason: LossReason, at timestamp: Date) -> Self {
        Self(timestamp: timestamp, quad: nil, confidence: 0, status: .lost(reason))
    }
}

public enum PanelTrackingError: Error, Equatable {
    /// The reference quad isn't a convex, clockwise, non-degenerate panel.
    case invalidReferenceQuad
    /// The reference photo's bytes couldn't be decoded.
    case unreadableReferencePhoto
    /// Vision couldn't hold the rectangle even in the reference image itself.
    case registrationFailed
    /// `startTracking` or `stopTracking` ran while this call was waiting on
    /// Vision. Its result belonged to the old session and was discarded.
    case superseded
    /// `track` was called again before the previous frame finished. Frames
    /// must be fed sequentially; the tracking state is a chain.
    case frameInFlight
}

/// Follows the panel from frame to frame as the phone moves.
///
/// An actor because Vision's tracking request is stateful: each update starts
/// from where the last one ended, so exactly one sequence of frames may touch it.
public actor PanelTracker {

    private struct Session {
        let id: UInt64
        /// The sequence following the camera. `nil` until the first frame,
        /// and again after a loss: Vision's sequence doesn't recover by itself.
        var tracker: (any RectangleTracking)?
        /// Last tracked quad, used to keep corner identities stable and to
        /// start again from after a loss.
        var previous: PanelQuad
        /// An image showing the panel at `previous`: the reference photo until
        /// the first tracked frame, then the last tracked frame.
        var lastSeen: TrackerImage
        /// What the panel looks like in the reference photo, to check that what
        /// a restart or re-finding found is the panel. `nil` if it couldn't be
        /// learned: restarts go unchecked and there's no re-finding.
        let appearance: (any PanelAppearance)?
        var updating = false
    }

    /// A re-detected rectangle further than this from the panel's appearance
    /// isn't the panel. Feature-print distance. On the synthetic fixtures the
    /// panel scores ~0.03 (0.11 with corners 2% off), a same-shaped rectangle
    /// without buttons 0.65, bare wall 0.9. Retune on real photos.
    static let maximumAppearanceDistance = 0.3
    /// The best rectangle must be clearly more like the panel than the
    /// runner-up (best < ratio × runner-up), or it's a guess.
    static let ambiguityRatio = 0.8

    private let makeTracker: @Sendable (PanelQuad) -> any RectangleTracking
    private let detector: any RectangleDetecting
    private let learnAppearance: @Sendable (PanelQuad, CGImage, CGImagePropertyOrientation) async throws -> (any PanelAppearance)?
    private let minimumConfidence: Double
    private var session: Session?
    /// Bumped by every start and stop, so in-flight work can tell it's stale.
    private var generation: UInt64 = 0

    public init(minimumConfidence: Double = TrackingQualityThresholds().panelFloor) {
        self.init(minimumConfidence: minimumConfidence, detector: VisionRectangleDetector(),
                  learnAppearance: { try await VisionPanelAppearance(panel: $0, in: $1, orientation: $2) }) {
            VisionRectangleTracker(start: $0)
        }
    }

    // Keep the Vision boundary replaceable for deterministic tests.
    init(minimumConfidence: Double = TrackingQualityThresholds().panelFloor,
         detector: any RectangleDetecting = NoRectangles(),
         learnAppearance: @escaping @Sendable (PanelQuad, CGImage, CGImagePropertyOrientation) async throws
            -> (any PanelAppearance)? = { _, _, _ in nil },
         makeTracker: @escaping @Sendable (PanelQuad) -> any RectangleTracking) {
        self.detector = detector
        self.learnAppearance = learnAppearance
        self.minimumConfidence = minimumConfidence
        self.makeTracker = makeTracker
    }

    /// Begin tracking using the matching reference image, quad, and button map.
    ///
    /// The reference preserves the pixels, orientation, and logical corner identities
    /// established by Surface Understanding. Replaces any current session, so this
    /// is also the manual restart.
    public func startTracking(_ reference: PanelReference) async throws {
        let quad = reference.detection.quad
        guard PanelHomography.isValid(quad) else { throw PanelTrackingError.invalidReferenceQuad }
        guard let source = CGImageSourceCreateWithData(reference.photo.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PanelTrackingError.unreadableReferencePhoto
        }

        stopTracking()
        let id = generation
        // Register on a throwaway sequence: it proves Vision can hold the panel
        // in the reference itself. The camera frames get their own sequence,
        // started on the first frame (see `track`), because Vision's tracker
        // fails outright when the image size changes and the reference photo
        // is rarely the camera's size.
        let registration = makeTracker(quad)
        let orientation = Self.orientation(reference.photo.orientation)
        let still = TrackerImage.still(image, orientation)

        let registered: VisionQuad?
        do {
            registered = try await registration.update(still)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == id else { throw PanelTrackingError.superseded }
            throw PanelTrackingError.registrationFailed
        }
        guard generation == id else { throw PanelTrackingError.superseded }

        guard case let .tracked(start, _) = evaluate(registered, previous: quad) else {
            throw PanelTrackingError.registrationFailed
        }

        // Re-finding is a fallback, so failing to learn the panel's appearance
        // only turns it off; it doesn't fail registration.
        let appearance: (any PanelAppearance)?
        do {
            appearance = try await learnAppearance(start, image, orientation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            appearance = nil
        }
        guard generation == id else { throw PanelTrackingError.superseded }

        session = Session(id: id, tracker: nil, previous: start, lastSeen: still, appearance: appearance)
    }

    /// Advance tracking by one camera frame. Call sequentially, in capture order.
    ///
    /// Returns a lost observation rather than throwing when the panel isn't
    /// usable, so callers can keep emitting. Throws only for cancellation and
    /// for results that no longer belong to the current session.
    public func track(_ frame: CameraFrame) async throws -> PanelObservation {
        guard let current = session else { return .lost(.notStarted, at: frame.timestamp) }
        guard !current.updating else { throw PanelTrackingError.frameInFlight }

        session?.updating = true
        let result: Result<VisionQuad?, any Error>
        do {
            let tracker: any RectangleTracking
            if let running = current.tracker {
                tracker = running
            } else {
                // A new sequence learns the panel from the first image it sees,
                // so show it the panel where we last saw it, at this frame's
                // size, before asking it to find the panel in this frame.
                tracker = makeTracker(current.previous)
                _ = try await tracker.update(try Self.resized(current.lastSeen, like: frame))
                if session?.id == current.id { session?.tracker = tracker }
            }
            result = .success(try await tracker.update(.frame(frame)))
        } catch {
            result = .failure(error)
        }
        // Actor reentrancy: start/stop may have run during the await above.
        guard session?.id == current.id else { throw PanelTrackingError.superseded }
        defer { if session?.id == current.id { session?.updating = false } }

        let reason: PanelObservation.LossReason
        switch result {
        case .failure(let error as CancellationError):
            throw error
        case .failure:
            reason = .trackerFailed
        case .success(let raw):
            switch evaluate(raw, previous: current.previous) {
            case let .tracked(quad, confidence):
                // A restarted sequence follows any clean-edged rectangle near
                // where the panel was, so check it's the panel. A running one
                // has been on the panel since a frame that passed this check.
                if current.tracker == nil, try await !looksLikePanel(quad, in: frame, current) {
                    reason = .unrecognized
                    break
                }
                guard session?.id == current.id else { throw PanelTrackingError.superseded }
                session?.previous = quad
                session?.lastSeen = .frame(frame)
                return .tracked(quad, confidence: confidence, at: frame.timestamp)
            case let .lost(lossReason):
                reason = lossReason
            }
        }
        session?.tracker = nil

        // A fresh sequence couldn't find the panel near where we last saw it:
        // the phone moved too far while we weren't following it. Look for it
        // anywhere in this frame and start following it from there.
        if current.tracker == nil, let found = try await reacquire(in: frame, for: current) {
            return found
        }
        return .lost(reason, at: frame.timestamp)
    }

    /// The rectangle in `frame` that looks like the registered panel, if one
    /// clearly does. Starts a new sequence on it.
    private func reacquire(in frame: CameraFrame, for current: Session) async throws -> PanelObservation? {
        guard let appearance = current.appearance else { return nil }
        let candidates: [VisionQuad]
        do {
            candidates = try await detector.detect(in: frame)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        // Size and position can't tell the panel from a cabinet door next to
        // it; what's inside the rectangle can.
        var scored: [(quad: PanelQuad, distance: Double)] = []
        for raw in candidates where raw.confidence.isFinite && raw.confidence >= minimumConfidence {
            let quad = Self.aligned(Self.imageQuad(raw), to: current.previous)
            guard PanelHomography.isValid(quad) else { continue }
            do {
                let distance = try await appearance.distance(of: quad, in: frame)
                if distance.isFinite { scored.append((quad, distance)) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        guard session?.id == current.id else { throw PanelTrackingError.superseded }
        guard let match = Self.clearMatch(scored) else { return nil }

        // The new sequence learns the panel from this frame. Its answer gets
        // the same checks as any other frame's.
        let tracker = makeTracker(match)
        let raw: VisionQuad?
        do {
            raw = try await tracker.update(.frame(frame))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard session?.id == current.id else { throw PanelTrackingError.superseded }
        guard case let .tracked(quad, confidence) = evaluate(raw, previous: match) else { return nil }

        session?.tracker = tracker
        session?.previous = quad
        session?.lastSeen = .frame(frame)
        return .tracked(quad, confidence: confidence, at: frame.timestamp)
    }

    /// Whether `quad` in `frame` looks like the registered panel. Unchecked
    /// (true) when the panel's appearance couldn't be learned.
    private func looksLikePanel(_ quad: PanelQuad, in frame: CameraFrame, _ current: Session) async throws -> Bool {
        guard let appearance = current.appearance else { return true }
        do {
            return try await appearance.distance(of: quad, in: frame) <= Self.maximumAppearanceDistance
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// The quad that looks most like the panel, if it's alike enough and no
    /// other quad comes close: two equally good candidates is a guess.
    static func clearMatch(_ scored: [(quad: PanelQuad, distance: Double)]) -> PanelQuad? {
        let ranked = scored.sorted { $0.distance < $1.distance }
        guard let best = ranked.first, best.distance <= maximumAppearanceDistance else { return nil }
        if ranked.count > 1, best.distance >= ambiguityRatio * ranked[1].distance { return nil }
        return best.quad
    }

    /// The panel's pose for the current frame.
    ///
    /// Always `.unknown` for now: metric 3D pose is outside issue #8's scope, and
    /// an identity transform with real confidence would be a lie. Use `track(_:)`.
    public func currentPose() async -> PanelPose {
        .unknown
    }

    /// Stop tracking and drop the session; the app owns the camera.
    ///
    /// Idempotent and never suspends, so it's safe to call from
    /// `AsyncStream.onTermination` via `Task { await tracker.stopTracking() }`.
    public func stopTracking() {
        generation &+= 1
        session = nil
    }

    // MARK: - Vision → image space

    private enum Verdict {
        case tracked(PanelQuad, Double)
        case lost(PanelObservation.LossReason)
    }

    private func evaluate(_ raw: VisionQuad?, previous: PanelQuad) -> Verdict {
        guard let raw else { return .lost(.notFound) }
        guard raw.confidence.isFinite, raw.confidence >= minimumConfidence else {
            return .lost(.lowConfidence)
        }
        let quad = Self.aligned(Self.imageQuad(raw), to: previous)
        guard PanelHomography.isValid(quad) else { return .lost(.invalidGeometry) }
        return .tracked(quad, min(raw.confidence, 1))
    }

    /// Vision is lower-left origin, y up; `ImagePoint` is top-left origin, y down.
    /// Both are normalized to the upright (oriented) image.
    static func imageQuad(_ raw: VisionQuad) -> PanelQuad {
        func flip(_ p: SIMD2<Double>) -> ImagePoint { ImagePoint(x: p.x, y: 1 - p.y) }
        return PanelQuad(topLeft: flip(raw.topLeft), topRight: flip(raw.topRight),
                         bottomRight: flip(raw.bottomRight), bottomLeft: flip(raw.bottomLeft))
    }

    /// Vision names corners by where they are on screen; we name them by which
    /// panel corner they are. If the phone rolls past 45°, Vision's "top left"
    /// becomes a different physical corner. Pick the cyclic relabelling (which
    /// keeps the winding) that moves the corners least since the last frame.
    static func aligned(_ quad: PanelQuad, to previous: PanelQuad) -> PanelQuad {
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        let before = [previous.topLeft, previous.topRight, previous.bottomRight, previous.bottomLeft]
        let best = (0..<4).min { a, b in cost(corners, before, a) < cost(corners, before, b) } ?? 0
        let c = (0..<4).map { corners[($0 + best) % 4] }
        return PanelQuad(topLeft: c[0], topRight: c[1], bottomRight: c[2], bottomLeft: c[3])
    }

    private static func cost(_ corners: [ImagePoint], _ before: [ImagePoint], _ shift: Int) -> Double {
        (0..<4).reduce(0) { sum, i in
            let p = corners[(i + shift) % 4], q = before[i]
            return sum + (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
        }
    }

    /// `image` drawn upright at `frame`'s upright size. A frame is already that
    /// size; the reference photo is redrawn, since its normalized corners are
    /// relative to the upright image and stay valid when it's scaled.
    static func resized(_ image: TrackerImage, like frame: CameraFrame) throws -> TrackerImage {
        guard case let .still(cgImage, orientation) = image else { return image }

        var width = CVPixelBufferGetWidth(frame.pixelBuffer)
        var height = CVPixelBufferGetHeight(frame.pixelBuffer)
        if [.left, .right, .leftMirrored, .rightMirrored].contains(frame.orientation) {
            swap(&width, &height)
        }

        let upright = CIImage(cgImage: cgImage).oriented(orientation)
        let scaled = upright
            .transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / upright.extent.width,
                                               y: CGFloat(height) / upright.extent.height))
        guard let resized = CIContext().createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height))
        else { throw PanelTrackingError.unreadableReferencePhoto }
        return .still(resized, .up)
    }

    private static func orientation(_ orientation: PhotoOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }
}
