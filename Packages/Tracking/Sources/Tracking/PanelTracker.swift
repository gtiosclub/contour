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
        /// Vision's tracking sequence errored. Stays lost until restarted.
        case trackerFailed
    }

    /// The camera frame's capture time, not when processing finished.
    public let timestamp: Date
    /// TL/TR/BR/BL keep their logical identities. `nil` exactly when lost.
    public let quad: PanelQuad?
    /// `0...1`; `0` when lost.
    public let confidence: Double
    public let status: Status

    static func tracked(_ quad: PanelQuad, confidence: Double, at timestamp: Date) -> Self {
        Self(timestamp: timestamp, quad: quad, confidence: confidence, status: .tracked)
    }

    static func lost(_ reason: LossReason, at timestamp: Date) -> Self {
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
        let tracker: any RectangleTracking
        /// Last tracked quad, used to keep corner identities stable.
        var previous: PanelQuad
        var updating = false
        /// Set once Vision's sequence errors; no automatic reacquisition.
        var failure: PanelObservation.LossReason?
    }

    private let makeTracker: @Sendable (PanelQuad) -> any RectangleTracking
    private let minimumConfidence: Double
    private var session: Session?
    /// Bumped by every start and stop, so in-flight work can tell it's stale.
    private var generation: UInt64 = 0

    public init(minimumConfidence: Double = TrackingQualityThresholds().panelFloor) {
        self.init(minimumConfidence: minimumConfidence) { VisionRectangleTracker(start: $0) }
    }

    // Keep the Vision boundary replaceable for deterministic tests.
    init(minimumConfidence: Double = TrackingQualityThresholds().panelFloor,
         makeTracker: @escaping @Sendable (PanelQuad) -> any RectangleTracking) {
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
        let tracker = makeTracker(quad)

        let registered: VisionQuad?
        do {
            registered = try await tracker.update(
                .still(image, Self.orientation(reference.photo.orientation)))
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
        session = Session(id: id, tracker: tracker, previous: start)
    }

    /// Advance tracking by one camera frame. Call sequentially, in capture order.
    ///
    /// Returns a lost observation rather than throwing when the panel isn't
    /// usable, so callers can keep emitting. Throws only for cancellation and
    /// for results that no longer belong to the current session.
    public func track(_ frame: CameraFrame) async throws -> PanelObservation {
        guard let current = session else { return .lost(.notStarted, at: frame.timestamp) }
        if let failure = current.failure { return .lost(failure, at: frame.timestamp) }
        guard !current.updating else { throw PanelTrackingError.frameInFlight }

        session?.updating = true
        let result: Result<VisionQuad?, any Error>
        do {
            result = .success(try await current.tracker.update(.frame(frame)))
        } catch {
            result = .failure(error)
        }
        // Actor reentrancy: start/stop may have run during the await above.
        guard session?.id == current.id else { throw PanelTrackingError.superseded }
        session?.updating = false

        switch result {
        case .failure(let error as CancellationError):
            throw error
        case .failure:
            session?.failure = .trackerFailed
            return .lost(.trackerFailed, at: frame.timestamp)
        case .success(let raw):
            switch evaluate(raw, previous: current.previous) {
            case let .tracked(quad, confidence):
                session?.previous = quad
                return .tracked(quad, confidence: confidence, at: frame.timestamp)
            case let .lost(reason):
                return .lost(reason, at: frame.timestamp)
            }
        }
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

    private static func orientation(_ orientation: PhotoOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }
}
