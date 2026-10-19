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

        // MARK: After calibration

        /// Once calibrated, how far a visual match may sit from the projected
        /// model and still count as the same panel. Looser than the calibration
        /// gates on purpose: these decide whether to *correct*, and refusing an
        /// honest correction costs more here than accepting a slightly noisy one.
        public var correctedRMS = 0.025
        public var correctedCornerError = 0.04

        /// Share of the stored corners kept when correcting. Corrections are
        /// deliberately slow: competing image estimates would otherwise make the
        /// target twitch, and the panel is not actually moving.
        public var smoothing = 0.8

        /// Confidence reported for a position that came from prediction rather
        /// than from seeing the panel. Below the strong-visual gate by design.
        public var worldConfidence = 0.55

        /// How long a verified prediction may continue while a visual match
        /// disagrees with it. Long enough to ride out a reflection, short enough
        /// that a genuinely moved panel is not guided to for long.
        public var conflictGrace: TimeInterval = 0.4

        /// Disagreement this persistent means the model is wrong, not the match:
        /// this many conflicting observations spanning this long.
        public var conflictsBeforeReset = 3
        public var conflictSpanForReset: TimeInterval = 0.4

        /// How long without a visual correction before asking integration to
        /// restore the original reference features.
        public var featureRestoreAfter: TimeInterval = 0.7

        /// Saturated fraction above which a failed visual alignment is *suspected*
        /// to be glare. Heuristic evidence for the UI, never a reason to trust
        /// or distrust geometry on its own.
        public var glareSaturation = 0.15

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

    /// This frame's capture time, so diagnostics can age the last verification.
    private var frameTimestamp: Date?
    /// Last agreeing visual match. Conflicting matches never touch it.
    private var verifiedAt: Date?
    /// Timestamps of the current run of disagreeing strong matches. Agreement
    /// clears it.
    private var conflicts: [Date] = []
    /// Prediction is withheld until an agreeing visual match verifies the model
    /// again — after unreliable world tracking, or after conflict grace expires.
    private var predictionPaused = false
    /// So a restoration request is one event, not one per frame.
    private var requestedRestore = false
    private var lastRMS: Double?
    private var lastCornerError: Double?

    public init(thresholds: Thresholds = Thresholds(), limits: WorldGeometryLimits = WorldGeometryLimits()) {
        self.thresholds = thresholds
        self.limits = limits
    }

    // MARK: Update

    /// Take one frame's visual observation and its same-frame world snapshot.
    ///
    /// Before calibration this returns the visual observation with progress
    /// attached. After it, this is the fusion state machine: correct the model
    /// from agreeing visual evidence, project it when the panel is out of sight,
    /// withhold it when the two disagree. The event flags describe *this* update
    /// only, never history.
    public mutating func update(visual: PanelObservation, world: WorldCameraSnapshot?) -> PanelObservation {
        acceptedCalibrationView = false
        didReset = false
        needsFeatureRestore = false
        frameTimestamp = visual.timestamp

        guard let world else {
            // No world frame at all: 2D is all we have, and corners in a frame
            // we can no longer locate are worse than none.
            discard(reason: "No world snapshot")
            return report(visual, mode: .visual, message: "2D only: no world data")
        }

        if let stored = model?.sessionID ?? candidate?.sessionID, stored != world.sessionID {
            // The coordinate frame changed underneath the stored corners.
            discard(reason: "World session replaced")
            return report(visual, mode: .visual, message: "Restarting: world session replaced")
        }

        guard world.normalTracking else {
            // Pause prediction at once and wait for agreeing visual evidence
            // before resuming — but keep the calibration, since this is usually
            // a passing limitation rather than a wrong model.
            predictionPaused = true
            guard model != nil else {
                return report(visual, mode: candidate == nil ? .visual : .calibrating,
                              message: "World tracking unreliable: holding progress")
            }
            return reacquiring(visual, message: "World tracking unreliable: prediction paused")
        }

        guard let geometry = try? PanelWorldGeometry(snapshot: world, limits: limits) else {
            guard model != nil else {
                return report(visual, mode: candidate == nil ? .visual : .calibrating,
                              message: "Unusable camera geometry")
            }
            return reacquiring(visual, message: "Unusable camera geometry")
        }

        if model != nil {
            return fuse(visual: visual, geometry: geometry)
        }

        guard let quad = visual.quad else {
            return report(visual, mode: candidate == nil ? .visual : .calibrating,
                          message: "Waiting for the panel to be seen again")
        }
        if candidate == nil {
            return startCandidate(visual: visual, quad: quad, world: world, geometry: geometry)
        }
        return extendCandidate(visual: visual, quad: quad, world: world, geometry: geometry)
    }

    /// Throw the model away because the panel being tracked has changed.
    ///
    /// A world session change is visible in the snapshot, but a replaced
    /// `PanelReference` is not: corners measured against the old reference are
    /// meaningless against a new one, and only the coordinator knows it
    /// happened. Calling this is how it says so, instead of dropping the whole
    /// policy and losing the reset event.
    public mutating func invalidate(reason: String = "Reference replaced") {
        acceptedCalibrationView = false
        needsFeatureRestore = false
        didReset = false
        discard(reason: reason)
    }

    // MARK: Fusion

    /// One frame of the calibrated state machine.
    private mutating func fuse(visual: PanelObservation, geometry: PanelWorldGeometry) -> PanelObservation {
        guard var model else { return report(visual, mode: .visual, message: "2D only") }
        let now = visual.timestamp
        let projected = try? geometry.quad(for: model.corners)

        // A strong visual match is the only thing allowed to move the model.
        if let quad = visual.quad, visual.confidence >= thresholds.strongVisualConfidence,
           let projected {
            let cornerError = Self.worstCorner(projected, quad)
            let rms = Self.interiorRMS(projected, quad, samples: thresholds.interiorSamples)
            lastCornerError = cornerError
            lastRMS = rms

            if let rms, cornerError <= thresholds.correctedCornerError, rms <= thresholds.correctedRMS {
                return correct(model: &model, towards: quad, visual: visual, geometry: geometry,
                               fallback: projected, at: now)
            }
            return conflicted(visual: visual, projected: projected, at: now)
        }

        // Nothing to correct from this frame: predict, if prediction is allowed.
        noteRestoreRequest(at: now)
        if predictionPaused || graceExpired(at: now) {
            predictionPaused = true
            return reacquiring(visual, message: "Waiting to see the panel again")
        }
        guard let projected else {
            // Never hand back the last screen position instead: a projection
            // that fails means we do not know where the panel is now.
            return unavailable(visual, message: "Panel not projectable from here")
        }
        return accepted(projected, confidence: thresholds.worldConfidence, from: visual,
                        source: .world, mode: .predicted, message: "AR prediction")
    }

    /// Nudge the stored corners towards what the camera just saw, then project
    /// the corrected model. Smoothing happens to the world corners, not to the
    /// output, so competing image estimates cannot make the target jump.
    private mutating func correct(
        model: inout CalibratedPanelModel, towards quad: PanelQuad, visual: PanelObservation,
        geometry: PanelWorldGeometry, fallback: PanelQuad, at now: Date
    ) -> PanelObservation {
        verifiedAt = now
        conflicts.removeAll()
        predictionPaused = false
        requestedRestore = false

        // Corrections stay on the retained plane: a correction is about where on
        // that surface the panel is, never about changing its depth.
        if let measured = try? geometry.corners(of: quad, on: model.plane) {
            model.corners = Self.smoothed(model.corners, towards: measured, keeping: thresholds.smoothing)
            self.model = model
        }

        let corrected = (try? geometry.quad(for: model.corners)) ?? fallback
        return accepted(corrected, confidence: visual.confidence, from: visual,
                        source: .fused, mode: .corrected, message: "2D-corrected AR")
    }

    /// A strong match that does not agree. It corrects nothing, and it does not
    /// refresh the verification time either.
    private mutating func conflicted(
        visual: PanelObservation, projected: PanelQuad, at now: Date
    ) -> PanelObservation {
        conflicts.append(now)
        noteRestoreRequest(at: now)

        let glare = (visual.featureDiagnostics?.saturatedFraction ?? 0) > thresholds.glareSaturation
        let reason: HybridTrackingDiagnostics.RepositionReason = glare ? .suspectedGlare : .weakAlignment

        if conflictIsConclusive(at: now) {
            // Enough disagreement for long enough: it is the model that is
            // wrong. Back to visual-led calibration.
            discard(reason: "Visual and world disagree")
            return report(visual, mode: .visual, message: "Realigning from 2D", reposition: reason)
        }

        if !predictionPaused, !graceExpired(at: now) {
            // Brief grace: keep the verified prediction rather than jumping to a
            // displaced match. This is the reflection case.
            return accepted(projected, confidence: thresholds.worldConfidence, from: visual,
                            source: .world, mode: .predicted,
                            message: glare ? "Ignoring a suspect match: possible glare"
                                           : "Ignoring a displaced match",
                            reposition: reason)
        }

        // Grace is over but the evidence is not yet conclusive: assert nothing.
        predictionPaused = true
        return unavailable(visual, message: "Visual and world still disagree", reposition: reason)
    }

    // MARK: Fusion state

    /// Grace runs from the first conflict, so it expires even if further matches
    /// stop arriving.
    private func graceExpired(at now: Date) -> Bool {
        guard let first = conflicts.first else { return false }
        return now.timeIntervalSince(first) > thresholds.conflictGrace
    }

    /// Enough conflicting observations, spanning enough time, to blame the model.
    private func conflictIsConclusive(at now: Date) -> Bool {
        guard conflicts.count >= thresholds.conflictsBeforeReset, let first = conflicts.first else {
            return false
        }
        return now.timeIntervalSince(first) >= thresholds.conflictSpanForReset
    }

    /// Ask integration to restore the original reference features. Fires once
    /// per dry spell: it is an event, not a condition.
    private mutating func noteRestoreRequest(at now: Date) {
        guard !requestedRestore, let verifiedAt,
              now.timeIntervalSince(verifiedAt) >= thresholds.featureRestoreAfter else { return }
        needsFeatureRestore = true
        requestedRestore = true
    }

    /// Weighted towards the stored corners by `keeping`.
    static func smoothed(
        _ stored: WorldPanelCorners, towards measured: WorldPanelCorners, keeping: Double
    ) -> WorldPanelCorners {
        func blend(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            a * keeping + b * (1 - keeping)
        }
        return WorldPanelCorners(
            topLeft: blend(stored.topLeft, measured.topLeft),
            topRight: blend(stored.topRight, measured.topRight),
            bottomRight: blend(stored.bottomRight, measured.bottomRight),
            bottomLeft: blend(stored.bottomLeft, measured.bottomLeft)
        )
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
        lastCornerError = cornerError
        lastRMS = rms

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
        // Approval came from an agreeing view, so verification starts now rather
        // than waiting for the first post-calibration correction.
        verifiedAt = visual.timestamp
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
        verifiedAt = nil
        conflicts.removeAll()
        predictionPaused = false
        requestedRestore = false
        didReset = true
        resetCount += 1
        lastResetReason = reason
    }

    private func cameraPosition(_ world: WorldCameraSnapshot) -> SIMD3<Double> {
        let column = world.cameraToWorld.columns.3
        return SIMD3(Double(column.x), Double(column.y), Double(column.z))
    }

    /// Hand the caller's own visual observation straight back, with progress
    /// attached. The source is `.visual` because that is genuinely what they are
    /// getting — nothing here was fused or predicted.
    private func report(
        _ visual: PanelObservation,
        mode: HybridTrackingDiagnostics.Mode,
        message: String,
        reposition: HybridTrackingDiagnostics.RepositionReason? = nil
    ) -> PanelObservation {
        var observation = visual
        observation.hybridDiagnostics = diagnostics(
            mode: mode, message: message,
            source: visual.quad == nil ? .unavailable : .visual,
            reposition: reposition)
        return observation
    }

    /// Geometry this policy is willing to stand behind, from `source`.
    ///
    /// The quad is always computed from the model this frame. A stale screen
    /// position is never passed off as a current one.
    private func accepted(
        _ quad: PanelQuad,
        confidence: Double,
        from visual: PanelObservation,
        source: HybridTrackingDiagnostics.Source,
        mode: HybridTrackingDiagnostics.Mode,
        message: String,
        reposition: HybridTrackingDiagnostics.RepositionReason? = nil
    ) -> PanelObservation {
        var observation = PanelObservation.tracked(quad, confidence: confidence, at: visual.timestamp)
        observation.featureDiagnostics = visual.featureDiagnostics
        observation.hybridDiagnostics = diagnostics(
            mode: mode, message: message, source: source, reposition: reposition)
        return observation
    }

    /// No usable alignment this frame. A lost visual keeps its own reason;
    /// otherwise the panel was found somewhere this model cannot explain.
    private func unavailable(
        _ visual: PanelObservation,
        message: String,
        reposition: HybridTrackingDiagnostics.RepositionReason? = nil
    ) -> PanelObservation {
        let reason: PanelObservation.LossReason
        if case let .lost(visualReason) = visual.status {
            reason = visualReason
        } else {
            reason = .unrecognized
        }
        var observation = PanelObservation.lost(reason, at: visual.timestamp)
        observation.featureDiagnostics = visual.featureDiagnostics
        observation.hybridDiagnostics = diagnostics(
            mode: .reacquiring, message: message, source: .unavailable, reposition: reposition)
        return observation
    }

    /// Prediction is withheld pending agreeing visual verification. Any 2D the
    /// caller still has is better than nothing, so pass it through.
    private func reacquiring(_ visual: PanelObservation, message: String) -> PanelObservation {
        guard visual.quad != nil else { return unavailable(visual, message: message) }
        return report(visual, mode: .reacquiring, message: message)
    }

    /// Unknown measurements stay absent rather than being reported as zero.
    private func diagnostics(
        mode: HybridTrackingDiagnostics.Mode,
        message: String,
        source: HybridTrackingDiagnostics.Source,
        reposition: HybridTrackingDiagnostics.RepositionReason?
    ) -> HybridTrackingDiagnostics {
        HybridTrackingDiagnostics(
            mode: mode,
            message: message,
            calibrationFrames: candidate?.acceptedViews ?? 0,
            repositionReason: reposition,
            source: source,
            calibrationReady: isCalibrated,
            resetCount: resetCount,
            lastResetReason: lastResetReason,
            alignmentError: lastRMS,
            cornerError: lastCornerError,
            baselineCentimeters: (candidate?.baseline ?? 0) * 100,
            visualVerificationAge: verificationAge
        )
    }

    /// How long since the last agreeing visual match. Honest by construction:
    /// only `correct` ever sets the verification time.
    private var verificationAge: TimeInterval? {
        guard let verifiedAt, let frameTimestamp else { return nil }
        return frameTimestamp.timeIntervalSince(verifiedAt)
    }
}
