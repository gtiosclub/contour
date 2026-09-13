//
//  LiveSurfaceUnderstanding.swift
//  SurfaceUnderstanding — Team 1
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  EMPTY ROOM. This is Team 1's package and nobody else commits here.      │
//  │                                                                          │
//  │  Everything below is a stub. Replace the bodies, keep the signatures —   │
//  │  the signatures are ContourCore's contract and other teams are building  │
//  │  against them right now. Until this works, the app runs on               │
//  │  ContourMocks.MockSurfaceUnderstanding.                                  │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  A photo of a control panel goes in; a SurfaceMap comes out — what the buttons
//  are, where they sit, how sure we are.
//
//  COORDINATES
//  Everything you return is in normalized panel space: (0,0) top-left,
//  (1,1) bottom-right, y DOWNWARD. Vision hands you pixels in a y-up space —
//  convert before you return. No pixel coordinate leaves this package.
//  See Packages/ContourCore/COORDINATES.md.
//
//  NAMING WRINKLE
//  This module is called `SurfaceUnderstanding` and so is the protocol. Inside
//  this package the bare name resolves to the module, so the conformance has to
//  be spelled `ContourCore.SurfaceUnderstanding`. Everywhere else the bare name
//  is fine.
//

import ContourCore
import Foundation

/// The real panel detector. Team 1 builds this out.
///
/// Conforms to `ContourCore.SurfaceUnderstanding`. Fully qualified because the
/// module shares the protocol's name — see the note above.
public struct LiveSurfaceUnderstanding: ContourCore.SurfaceUnderstanding {

    public init() {}

    /// Detect the controls on the panel in `photo`.
    ///
    /// - Returns: a `SurfaceMap` in normalized panel space.
    /// - Throws: `SurfaceUnderstandingError`.
    public func surfaceMap(from photo: PanelPhoto) async throws -> SurfaceMap {
        fatalError("unimplemented — owned by Team 1 (SurfaceUnderstanding)")
    }
}
