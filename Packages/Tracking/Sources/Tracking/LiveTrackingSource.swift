//
//  LiveTrackingSource.swift
//  Tracking — Tracking / TrackingFrame emitter & latency
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  EMPTY ROOM. This is Tracking / Spatial's package, and nobody else       │
//  │  commits here.                                                           │
//  │                                                                          │
//  │  Everything below is a stub. Replace the bodies, keep the signatures —   │
//  │  the signatures are ContourCore's contract and other teams are building  │
//  │  against them right now. Until this works, the app runs on               │
//  │  ContourMocks.MockTrackingSource.                                        │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  A live stream of TrackingFrames: where the panel is relative to the camera,
//  where the user's fingertip is on the panel, and how much to trust either.
//
//  COORDINATES
//  `fingertip` is in normalized panel space: (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. Hand tracking gives you camera-space points — project them onto
//  the panel and normalize before you emit. Off-panel values are fine and useful;
//  do not clamp them. `PanelPose` is the one camera-space thing you emit, and it
//  is yours. See Packages/ContourCore/COORDINATES.md.
//
//  TWO RULES THAT WILL SAVE EVERYONE PAIN
//  1. Never go silent. When tracking drops, keep emitting `.lost(at:)` frames so
//     consumers can tell "no finger" from "no source".
//  2. Clean up in `onTermination`. The stream must stop the camera when the
//     consuming task is cancelled.
//

import ContourCore
import Foundation

/// The real tracker. Tracking / Spatial builds this out.
public struct LiveTrackingSource: TrackingSource {

    public init() {}

    /// Start tracking and return the stream of frames.
    ///
    /// - Returns: frames in normalized panel space, at camera rate.
    public func frames() -> AsyncStream<TrackingFrame> {
        fatalError("unimplemented — owned by Tracking / TrackingFrame emitter & latency")
    }
}
