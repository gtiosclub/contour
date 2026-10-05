//
//  LiveTrackingSource.swift
//  Tracking — Tracking / TrackingFrame emitter & latency
//
//  WHAT THIS PACKAGE OWES THE APP
//  A live stream of TrackingFrames: where the panel is relative to the camera,
//  where the user's fingertip is on the panel, and how much to trust either.
//
//  HOW A FRAME IS MADE
//  Camera frames are handled one at a time, in capture order:
//    1. PanelTracker finds the panel's corners in this frame.
//    2. FingertipTracker finds the index fingertip in the same frame.
//    3. PanelHomography maps the fingertip from the image onto the panel.
//    4. TrackingQualityEvaluator rates the frame.
//  The fingertip is lightly smoothed, and the smoothing starts over whenever
//  the finger or the panel is lost.
//
//  COORDINATES
//  `fingertip` is in normalized panel space: (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. Off-panel values are fine and useful; they aren't clamped.
//  `PanelPose` has no metric 3D pose yet: its transform is the identity and only
//  its confidence is real (the panel tracker's), so guidance can tell a solid
//  lock from a shaky one. See Packages/ContourCore/COORDINATES.md.
//
//  TWO RULES THAT WILL SAVE EVERYONE PAIN
//  1. Never go silent. When tracking drops, keep emitting `.lost(at:)` frames so
//     consumers can tell "no finger" from "no source".
//  2. Clean up in `onTermination`. The stream must release its frame subscription when the
//     consuming task is cancelled.
//

import ContourCore
import Foundation

/// The real tracker: the panel and the fingertip, live from the camera.
public struct LiveTrackingSource: TrackingSource {

    private let engine: Engine?

    /// A source with no camera: `frames()` finishes straight away.
    public init() {
        engine = nil
    }

    /// Track the panel and fingertip in `camera`'s frames.
    ///
    /// Frames are `.lost` until `use(_:)` hands over the panel to follow.
    public init(
        camera: any CameraFrameSource,
        panelTracker: PanelTracker = PanelTracker(),
        fingertipTracker: FingertipTracker = FingertipTracker(),
        evaluator: TrackingQualityEvaluator = TrackingQualityEvaluator()
    ) {
        engine = Engine(camera: camera, panelTracker: panelTracker,
                        fingertipTracker: fingertipTracker, evaluator: evaluator)
    }

    /// The panel to follow, from Surface Understanding's detection. Replaces any
    /// panel given before.
    public func use(_ reference: PanelReference) async {
        await engine?.use(reference)
    }

    /// Start tracking and return the stream of frames.
    ///
    /// One stream at a time: frames are a chain, so two streams would compete
    /// for the same panel tracker.
    ///
    /// - Returns: frames in normalized panel space, at camera rate.
    public func frames() -> AsyncStream<TrackingFrame> {
        guard let engine else { return AsyncStream { $0.finish() } }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await frame in await engine.cameraFrames() {
                    if Task.isCancelled { break }
                    continuation.yield(await engine.process(frame))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Everything that has to happen one frame at a time.
private actor Engine {

    private enum Panel {
        /// No panel handed over yet.
        case none
        /// Handed over; registers with the tracker on the next frame.
        case waiting(PanelReference)
        case tracking
        /// The tracker couldn't hold this panel even in its own photo.
        case unusable
    }

    private let camera: any CameraFrameSource
    private let panelTracker: PanelTracker
    private let fingertipTracker: FingertipTracker
    private let evaluator: TrackingQualityEvaluator

    private var panel = Panel.none
    private var previous: TrackingObservation?
    private var smoothed: PanelPoint?

    init(camera: any CameraFrameSource, panelTracker: PanelTracker,
         fingertipTracker: FingertipTracker, evaluator: TrackingQualityEvaluator) {
        self.camera = camera
        self.panelTracker = panelTracker
        self.fingertipTracker = fingertipTracker
        self.evaluator = evaluator
    }

    func cameraFrames() async -> AsyncStream<CameraFrame> {
        await camera.cameraFrames()
    }

    func use(_ reference: PanelReference) {
        panel = .waiting(reference)
        previous = nil
        smoothed = nil
    }

    func process(_ frame: CameraFrame) async -> TrackingFrame {
        switch panel {
        case .none, .unusable:
            return lost(frame)
        case .waiting(let reference):
            do {
                try await panelTracker.startTracking(reference)
                panel = .tracking
            } catch {
                panel = .unusable
                return lost(frame)
            }
        case .tracking:
            break
        }

        let observation: PanelObservation
        do {
            observation = try await panelTracker.track(frame)
        } catch {
            return lost(frame)
        }
        guard observation.status == .tracked, let quad = observation.quad,
              let homography = try? PanelHomography(quad: quad) else {
            return lost(frame)
        }

        let tip = try? await fingertipTracker.detect(in: frame)
        let fingertip = smooth(tip?.fingertip.flatMap { homography.panelPoint(for: $0) })

        let rated = TrackingObservation(
            timestamp: frame.timestamp,
            fingertipConfidence: fingertip == nil ? nil : tip?.confidence,
            panelQuad: quad,
            panelConfidence: observation.confidence
        )
        let assessment = evaluator.assess(rated, previous: previous, asOf: Date())
        previous = rated
        guard assessment.quality != .lost else { return lost(frame) }

        return TrackingFrame(
            timestamp: frame.timestamp,
            fingertip: fingertip,
            panel: PanelPose(
                column0: SIMD4(1, 0, 0, 0), column1: SIMD4(0, 1, 0, 0),
                column2: SIMD4(0, 0, 1, 0), column3: SIMD4(0, 0, 0, 1),
                confidence: observation.confidence
            ),
            trackingQuality: assessment.quality
        )
    }

    private func lost(_ frame: CameraFrame) -> TrackingFrame {
        smoothed = nil
        return .lost(at: frame.timestamp)
    }

    /// Halfway between the last smoothed point and the new one: steadier than
    /// the raw point, and still caught up within a few frames.
    private func smooth(_ point: PanelPoint?) -> PanelPoint? {
        guard let point else {
            smoothed = nil
            return nil
        }
        let next = smoothed.map { PanelPoint(x: ($0.x + point.x) / 2, y: ($0.y + point.y) / 2) } ?? point
        smoothed = next
        return next
    }
}
