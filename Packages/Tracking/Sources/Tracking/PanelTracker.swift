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
//  `PanelPose` is camera-space — it is the bridge between the physical world
//  and panel space, and it is the only camera-space value that leaves this
//  package. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Follows the panel from frame to frame as the phone moves.
public struct PanelTracker: Sendable {

    public init() {}

    /// Begin tracking using the matching reference image, quad, and button map.
    ///
    /// The reference preserves the pixels, orientation, and logical corner identities
    /// established by Surface Understanding.
    public func startTracking(_ reference: PanelReference) async throws {
        fatalError("unimplemented — owned by Tracking / Panel Registration & Lost Tracking")
    }

    /// The panel's pose for the current frame.
    ///
    /// - Returns: the pose and a confidence. Return a low-confidence pose rather
    ///   than nothing when the panel is partly visible — `.degraded` is a real
    ///   state and feedback softens rather than stops for it.
    public func currentPose() async -> PanelPose {
        fatalError("unimplemented — owned by Tracking / Panel Registration & Lost Tracking")
    }

    /// Stop tracking and release its frame subscription; the app owns the camera.
    ///
    /// Must be safe to call from `AsyncStream.onTermination`, which is where
    /// `LiveTrackingSource` will call it when its consumer is cancelled.
    public func stopTracking() async {
        fatalError("unimplemented — owned by Tracking / Panel Registration & Lost Tracking")
    }
}
