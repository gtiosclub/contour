//
//  HybridAlignment.swift
//  Tracking — Tracking / Geometry and fusion
//
//  Our own panel model, and the evidence needed before trusting it.
//
//  Calibration asks one question: is the plane we put the panel on actually at
//  the panel's depth? A wall behind a microwave answers the first camera view
//  perfectly well. It only disagrees once the phone has moved sideways, so this
//  collects separated, agreeing views and triangulates before approving.
//
//  Approval changes nothing the user sees: until task 3 fuses correction with
//  prediction, every update returns the visual observation it was handed. What
//  calibration adds is a validated model and an honest account of what is still
//  missing. It never touches ARKit's own map.
//

import ContourCore
import Foundation
import simd

// MARK: - CalibratedPanelModel

/// A panel model that has survived multi-view depth validation.
///
/// This is what task 3 projects during visual loss. It is only produced once
/// movement, agreement and depth evidence all pass.
public struct CalibratedPanelModel: Sendable {
    /// World corners on the approved plane, TL/TR/BR/BL preserved.
    public var corners: WorldPanelCorners
    /// The plane the corners lie on, kept so corrections stay on that surface.
    public var plane: WorldPlane
    /// The world session the corners are expressed in. A new session invalidates them.
    public var sessionID: UUID
    /// Distance from the first camera view to the panel, in metres. Several
    /// tolerances scale with it: a panel at 2 m earns more slack than one at 30 cm.
    public var firstDistance: Double
    /// How many separated, agreeing views went into the approval.
    public var acceptedViews: Int

    public init(corners: WorldPanelCorners, plane: WorldPlane, sessionID: UUID,
                firstDistance: Double, acceptedViews: Int) {
        self.corners = corners
        self.plane = plane
        self.sessionID = sessionID
        self.firstDistance = firstDistance
        self.acceptedViews = acceptedViews
    }
}

// MARK: - HybridAlignment

/// Keeps the panel model and decides when it may be trusted.
///
/// A struct because `PanelAlignmentPolicy.update` is `mutating`: the coordinator
/// owns the instance and feeds it frames in order. Task 3 extends this with the
/// correction/prediction/recovery state machine.
public struct HybridAlignment: PanelAlignmentPolicy {

    // MARK: Thresholds

    /// Starting values from issue #86. They are chosen to withhold approval on
    /// thin evidence, not to guarantee physical accuracy, and they want tuning
    /// against recorded sessions.
    public struct Thresholds: Hashable, Sendable {
        /// Below this, a visual quad is not a good enough place to start.
        public var strongVisualConfidence = 0.7

        /// Two accepted views must be at least this far apart in time...
        public var viewSpacingSeconds: TimeInterval = 0.12
        /// ...and the camera must have moved this far between them, in metres.
        /// An almost identical frame adds almost no depth evidence.
        public var viewSpacingTranslation = 0.004

        /// Projected-vs-observed interior RMS, in normalized image units.
        public var agreementRMS = 0.012
        /// Projected-vs-observed worst corner, in normalized image units.
        public var agreementCornerError = 0.025

        /// Readiness needs this many accepted views...
        public var readyViews = 8
        /// ...spanning this long...
        public var readySeconds: TimeInterval = 1.0
        /// ...with the camera this far from where it started, in metres.
        public var readyBaseline = 0.06

        /// Angle between the first and current view of the same panel point,
        /// in radians. Below this, triangulation is too ill-conditioned to
        /// prove depth — which is why turning on the spot never calibrates.
        public var minimumParallax: Double = 2 * .pi / 180

        /// How near the two rays must come to each other, in metres:
        /// `base + firstDistance × scale`.
        public var approachBase = 0.015
        public var approachScale = 0.005
        /// How near their meeting point must be to the candidate plane:
        /// `base + firstDistance × scale`. This is the guard a background wall
        /// fails.
        public var planeAgreementBase = 0.03
        public var planeAgreementScale = 0.03

        /// Panel-space coordinates sampled in each direction. These are
        /// *inferred* interior positions — nine corresponding points implied by
        /// the panel mapping, not nine separately detected landmarks.
        public var interiorSamples = [0.25, 0.5, 0.75]

        public init() {}
    }

    // MARK: State

    /// What we are collecting evidence about, before it is approved.
    private struct Candidate {
        let sessionID: UUID
        let plane: WorldPlane
        let corners: WorldPanelCorners
        let firstQuad: PanelQuad
        let firstGeometry: PanelWorldGeometry
        let firstTimestamp: Date
        let firstCamera: SIMD3<Double>
        let firstDistance: Double

        var acceptedViews = 1
        var lastAcceptedTimestamp: Date
        var lastAcceptedCamera: SIMD3<Double>
        /// Furthest the camera has been from where it started.
        var baseline = 0.0
        var elapsed: TimeInterval = 0
        var depthVerified = false
        var lastRMS: Double?
        var lastCornerError: Double?
    }

    public private(set) var isCalibrated = false
    public private(set) var acceptedCalibrationView = false
    public private(set) var didReset = false
    public private(set) var needsFeatureRestore = false

    /// The approved model, or `nil` while still gathering evidence.
    public private(set) var model: CalibratedPanelModel?

    public let thresholds: Thresholds
    public let limits: WorldGeometryLimits

    private var candidate: Candidate?
    private var resetCount = 0
    private var lastResetReason: String?

    public init(thresholds: Thresholds = Thresholds(), limits: WorldGeometryLimits = WorldGeometryLimits()) {
        self.thresholds = thresholds
        self.limits = limits
    }

    // MARK: Update

    /// Take one frame's visual observation and its same-frame world snapshot.
    ///
    /// Returns the visual observation, with calibration progress attached. The
    /// event flags describe *this* update only, never history.
    public mutating func update(visual: PanelObservation, world: WorldCameraSnapshot?) -> PanelObservation {
        acceptedCalibrationView = false
        didReset = false
        needsFeatureRestore = false

        guard let world else {
            // No world frame at all: 2D is all we have, and corners in a frame
            // we can no longer locate are worse than none.
            discard(reason: "No world snapshot")
            return report(visual, mode: .visual, message: "2D only: no world data")
        }

        if let candidate, candidate.sessionID != world.sessionID {
            // The coordinate frame changed underneath the stored corners.
            discard(reason: "World session replaced")
            return report(visual, mode: .visual, message: "Restarting: world session replaced")
        }

        guard let quad = visual.quad else {
            return report(visual, mode: candidate == nil ? .visual : .calibrating,
                          message: "Waiting for the panel to be seen again")
        }

        guard world.normalTracking else {
            // A temporary limitation. Keep the progress; just do not count this
            // view as evidence.
            return report(visual, mode: candidate == nil ? .visual : .calibrating,
                          message: "World tracking unreliable: holding progress")
        }

        guard let geometry = try? PanelWorldGeometry(snapshot: world, limits: limits) else {
            return report(visual, mode: candidate == nil ? .visual : .calibrating,
                          message: "Unusable camera geometry")
        }

        if candidate == nil {
            return startCandidate(visual: visual, quad: quad, world: world, geometry: geometry)
        }
        return extendCandidate(visual: visual, quad: quad, world: world, geometry: geometry)
    }

    // MARK: Starting a candidate

    private mutating func startCandidate(
        visual: PanelObservation, quad: PanelQuad,
        world: WorldCameraSnapshot, geometry: PanelWorldGeometry
    ) -> PanelObservation {
        guard visual.confidence >= thresholds.strongVisualConfidence else {
            return report(visual, mode: .visual, message: "Waiting for a confident view to start from")
        }
        guard let (plane, corners, distance) = nearestCandidatePlane(for: quad, in: world, with: geometry) else {
            return report(visual, mode: .visual, message: "No surface at the panel's position yet")
        }

        let camera = cameraPosition(world)
        candidate = Candidate(
            sessionID: world.sessionID,
            plane: plane,
            corners: corners,
            firstQuad: quad,
            firstGeometry: geometry,
            firstTimestamp: visual.timestamp,
            firstCamera: camera,
            firstDistance: distance,
            lastAcceptedTimestamp: visual.timestamp,
            lastAcceptedCamera: camera
        )
        acceptedCalibrationView = true
        return report(visual, mode: .calibrating, message: "Move the phone sideways a little")
    }

    /// The nearest plane the whole panel actually fits on.
    ///
    /// Nearest by first-corner distance, as the issue suggests, and only planes
    /// where all four corners intersect — a plane that explains one corner and
    /// misses the rest is not the panel's surface.
    private func nearestCandidatePlane(
        for quad: PanelQuad, in world: WorldCameraSnapshot, with geometry: PanelWorldGeometry
    ) -> (WorldPlane, WorldPanelCorners, Double)? {
        guard let ray = try? geometry.ray(through: quad.topLeft) else { return nil }

        var best: (plane: WorldPlane, corners: WorldPanelCorners, distance: Double)?
        for plane in world.planes {
            guard let topLeft = try? geometry.intersection(of: ray, with: plane),
                  let corners = try? geometry.corners(of: quad, on: plane) else { continue }
            let distance = simd_distance(ray.origin, topLeft)
            if best == nil || distance < best!.distance {
                best = (plane, corners, distance)
            }
        }
        guard let best else { return nil }
        return (best.plane, best.corners, best.distance)
    }

    // MARK: Extending a candidate

    private mutating func extendCandidate(
        visual: PanelObservation, quad: PanelQuad,
        world: WorldCameraSnapshot, geometry: PanelWorldGeometry
    ) -> PanelObservation {
        guard var candidate else { return report(visual, mode: .visual, message: "2D only") }

        let camera = cameraPosition(world)
        let sinceAccepted = visual.timestamp.timeIntervalSince(candidate.lastAcceptedTimestamp)
        let moved = simd_distance(camera, candidate.lastAcceptedCamera)

        guard sinceAccepted >= thresholds.viewSpacingSeconds,
              moved >= thresholds.viewSpacingTranslation else {
            // Not a new viewpoint, so not new evidence. Not a failure either.
            return report(visual, mode: .calibrating, message: "Move the phone sideways a little")
        }

        // Does the candidate still explain what the panel looks like from here?
        guard let projected = try? geometry.quad(for: candidate.corners) else {
            return report(visual, mode: .calibrating, message: "Candidate not visible from here")
        }
        let cornerError = Self.worstCorner(projected, quad)
        let rms = Self.interiorRMS(projected, quad, samples: thresholds.interiorSamples)
        candidate.lastCornerError = cornerError
        candidate.lastRMS = rms

        guard let rms, cornerError <= thresholds.agreementCornerError,
              rms <= thresholds.agreementRMS else {
            self.candidate = candidate
            return report(visual, mode: .calibrating, message: "View disagrees with the candidate")
        }

        candidate.acceptedViews += 1
        candidate.lastAcceptedTimestamp = visual.timestamp
        candidate.lastAcceptedCamera = camera
        candidate.baseline = max(candidate.baseline, simd_distance(camera, candidate.firstCamera))
        candidate.elapsed = visual.timestamp.timeIntervalSince(candidate.firstTimestamp)
        acceptedCalibrationView = true

        // Triangulate: where do the first and current views say the panel is?
        switch depthEvidence(for: candidate, quad: quad, geometry: geometry) {
        case .insufficientParallax:
            break // Keep collecting. Rotation alone never gets past this.
        case .verified:
            candidate.depthVerified = true
        case .contradicted:
            self.candidate = candidate
            discard(reason: "Candidate plane is at the wrong depth")
            return report(visual, mode: .visual, message: "Rejected that surface: wrong depth")
        }

        self.candidate = candidate
        return approveIfReady(visual: visual, candidate: candidate)
    }

    private mutating func approveIfReady(visual: PanelObservation, candidate: Candidate) -> PanelObservation {
        guard candidate.depthVerified else {
            return report(visual, mode: .calibrating, message: "Checking depth: keep moving sideways")
        }
        guard candidate.acceptedViews >= thresholds.readyViews else {
            return report(visual, mode: .calibrating,
                          message: "Collecting views (\(candidate.acceptedViews)/\(thresholds.readyViews))")
        }
        guard candidate.elapsed >= thresholds.readySeconds else {
            return report(visual, mode: .calibrating, message: "Hold on a moment longer")
        }
        guard candidate.baseline >= thresholds.readyBaseline else {
            return report(visual, mode: .calibrating, message: "A little more sideways movement")
        }

        isCalibrated = true
        model = CalibratedPanelModel(
            corners: candidate.corners,
            plane: candidate.plane,
            sessionID: candidate.sessionID,
            firstDistance: candidate.firstDistance,
            acceptedViews: candidate.acceptedViews
        )
        return report(visual, mode: .calibrating, message: "Panel depth confirmed")
    }

    // MARK: Depth

    private enum DepthEvidence {
        /// The two views are too alike to prove anything yet.
        case insufficientParallax
        /// The rays meet, and they meet on the candidate plane.
        case verified
        /// The rays meet somewhere the candidate plane is not.
        case contradicted
    }

    /// Compare the first and current views of the same inferred panel points.
    ///
    /// Each pair of rays should nearly meet — that is the correspondence being
    /// real — and meet near the candidate plane — that is the depth being right.
    /// A background wall passes the first test and fails the second.
    private func depthEvidence(
        for candidate: Candidate, quad: PanelQuad, geometry: PanelWorldGeometry
    ) -> DepthEvidence {
        guard let first = try? PanelHomography(quad: candidate.firstQuad),
              let now = try? PanelHomography(quad: quad) else {
            return .insufficientParallax
        }

        let planeToWorld = candidate.plane.transform
        let normal = simd_normalize(SIMD3<Double>(
            Double(planeToWorld.columns.1.x), Double(planeToWorld.columns.1.y), Double(planeToWorld.columns.1.z)))
        let planeOrigin = SIMD3<Double>(
            Double(planeToWorld.columns.3.x), Double(planeToWorld.columns.3.y), Double(planeToWorld.columns.3.z))

        let approachLimit = thresholds.approachBase + candidate.firstDistance * thresholds.approachScale
        let planeLimit = thresholds.planeAgreementBase + candidate.firstDistance * thresholds.planeAgreementScale

        var sawParallax = false
        for x in thresholds.interiorSamples {
            for y in thresholds.interiorSamples {
                let panelPoint = PanelPoint(x: x, y: y)
                guard let firstImage = first.imagePoint(for: panelPoint),
                      let nowImage = now.imagePoint(for: panelPoint),
                      let firstRay = try? candidate.firstGeometry.ray(through: firstImage),
                      let nowRay = try? geometry.ray(through: nowImage) else { continue }

                let angle = acos(min(1, max(-1, simd_dot(firstRay.direction, nowRay.direction))))
                guard angle >= thresholds.minimumParallax else { continue }
                sawParallax = true

                guard let meeting = Self.closestApproach(firstRay, nowRay) else { continue }
                guard meeting.separation <= approachLimit else { return .contradicted }
                let offPlane = abs(simd_dot(normal, meeting.point - planeOrigin))
                guard offPlane <= planeLimit else { return .contradicted }
            }
        }
        return sawParallax ? .verified : .insufficientParallax
    }

    /// Where two rays come closest, and how far apart they are there.
    /// `nil` when they are parallel enough that there is no single answer.
    static func closestApproach(_ a: WorldRay, _ b: WorldRay) -> (point: SIMD3<Double>, separation: Double)? {
        let between = a.origin - b.origin
        let cosine = simd_dot(a.direction, b.direction)
        let denominator = 1 - cosine * cosine
        guard denominator > 1e-12 else { return nil }

        let alongA = simd_dot(a.direction, between)
        let alongB = simd_dot(b.direction, between)
        let ta = (cosine * alongB - alongA) / denominator
        let tb = (alongB - cosine * alongA) / denominator
        guard ta.isFinite, tb.isFinite else { return nil }

        let pa = a.point(at: ta)
        let pb = b.point(at: tb)
        return ((pa + pb) / 2, simd_distance(pa, pb))
    }

    // MARK: Comparison

    /// The worst single corner displacement, in normalized image units.
    static func worstCorner(_ projected: PanelQuad, _ observed: PanelQuad) -> Double {
        zip([projected.topLeft, projected.topRight, projected.bottomRight, projected.bottomLeft],
            [observed.topLeft, observed.topRight, observed.bottomRight, observed.bottomLeft])
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? .infinity
    }

    /// RMS displacement over the inferred interior grid. `nil` if either quad
    /// cannot carry a homography.
    static func interiorRMS(_ projected: PanelQuad, _ observed: PanelQuad, samples: [Double]) -> Double? {
        guard let a = try? PanelHomography(quad: projected), let b = try? PanelHomography(quad: observed) else {
            return nil
        }
        var total = 0.0
        var count = 0
        for x in samples {
            for y in samples {
                let point = PanelPoint(x: x, y: y)
                guard let pa = a.imagePoint(for: point), let pb = b.imagePoint(for: point) else { continue }
                let dx = pa.x - pb.x, dy = pa.y - pb.y
                total += dx * dx + dy * dy
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (total / Double(count)).squareRoot()
    }

    // MARK: Bookkeeping

    private mutating func discard(reason: String) {
        guard candidate != nil || isCalibrated else { return }
        candidate = nil
        model = nil
        isCalibrated = false
        didReset = true
        resetCount += 1
        lastResetReason = reason
    }

    private func cameraPosition(_ world: WorldCameraSnapshot) -> SIMD3<Double> {
        let column = world.cameraToWorld.columns.3
        return SIMD3(Double(column.x), Double(column.y), Double(column.z))
    }

    /// Attach progress to the visual observation and hand it straight back.
    ///
    /// Unknown measurements stay absent rather than being reported as zero, and
    /// the source is `.visual` because that is what the caller is actually
    /// getting until task 3 fuses anything.
    private func report(
        _ visual: PanelObservation,
        mode: HybridTrackingDiagnostics.Mode,
        message: String
    ) -> PanelObservation {
        var observation = visual
        observation.hybridDiagnostics = HybridTrackingDiagnostics(
            mode: mode,
            message: message,
            calibrationFrames: candidate?.acceptedViews ?? 0,
            source: .visual,
            calibrationReady: isCalibrated,
            resetCount: resetCount,
            lastResetReason: lastResetReason,
            alignmentError: candidate?.lastRMS,
            cornerError: candidate?.lastCornerError,
            baselineCentimeters: (candidate?.baseline ?? 0) * 100
        )
        return observation
    }
}
