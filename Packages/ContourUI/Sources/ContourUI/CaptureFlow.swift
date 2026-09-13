//
//  CaptureFlow.swift
//  ContourUI — Team 4
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  EMPTY ROOM. This is Team 4's package and nobody else commits here.      │
//  │                                                                          │
//  │  Everything below is a stub. Replace the bodies, keep the signatures —   │
//  │  the signatures are ContourCore's contract and other teams are building  │
//  │  against them right now.                                                 │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  The camera experience and the target selection flow: point the phone at a
//  panel, take the shot, hand back a PanelPhoto; then show the SurfaceMap the
//  app gives you and let the user say which button they want.
//
//  WHAT YOU DO NOT DO HERE
//  You never call Team 1's detector yourself — you hand up a `PanelPhoto` and
//  the app target hands you back a `SurfaceMap`. Same for tracking and feedback.
//  ContourUI depends on ContourCore and nothing else, so none of those packages
//  are even importable from here. If you find yourself wanting one, that is the
//  signal to move the wiring into ContourApp.
//
//  ACCESSIBILITY IS THE PRODUCT
//  Contour exists for people who cannot see a microwave's flat panel. VoiceOver
//  is not a pass at the end — it is the primary interface. Every control you add
//  needs a label, a trait, and a rotor position on the day you add it.
//
//  COORDINATES
//  `SurfaceMap.Button.bounds` is in normalized panel space: (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. To draw an overlay, multiply by the preview
//  layer's size — and keep that multiplication inside this package. No pixel
//  coordinate goes back out. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// Drives capture: viewfinder, shutter, and the still that comes out of it.
///
/// Team 4 builds this out.
public struct CaptureFlow: Sendable {

    public init() {}

    /// Capture one still of the panel in front of the camera.
    ///
    /// - Returns: the photo, ready to hand to the app target for detection.
    public func capturePanelPhoto() async throws -> PanelPhoto {
        fatalError("unimplemented — owned by Team 4 (ContourUI)")
    }
}

/// Drives target selection: given what is on the panel, which button does the
/// user actually want?
///
/// Team 4 builds this out.
public struct TargetSelection: Sendable {

    public init() {}

    /// Ask the user which control on `map` they want to be guided to.
    ///
    /// - Returns: the chosen button, or `nil` if the user backed out. A request
    ///   for something that is not on the panel is `nil` here plus an
    ///   `OutcomeSignal.notFound` raised by the app target — not an error.
    public func selectTarget(in map: SurfaceMap) async -> SurfaceMap.Button? {
        fatalError("unimplemented — owned by Team 4 (ContourUI)")
    }
}
