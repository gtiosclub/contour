//
//  LiveSurfaceUnderstanding.swift
//  SurfaceUnderstanding — Surface / Officers (integration)
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  EMPTY ROOM. This is Surface Understanding's package, and nobody else    │
//  │  commits here.                                                           │
//  │                                                                          │
//  │  Everything below is a stub. Replace the bodies, keep the signatures —   │
//  │  the signatures are ContourCore's contract and other teams are building  │
//  │  against them right now. Until this works, the app runs on               │
//  │  ContourMocks.MockSurfaceUnderstanding.                                  │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  A photo goes in; PanelDetection returns its quad, map, and photo ID — what the buttons
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

/// The real panel detector. Surface Understanding builds this out.
///
/// Conforms to `ContourCore.SurfaceUnderstanding`. Fully qualified because the
/// module shares the protocol's name — see the note above.
public struct LiveSurfaceUnderstanding: ContourCore.SurfaceUnderstanding {

    public init() {}

    /// Detect controls using the returned quad for normalization. Echo photo.id.
    /// Quad corners use the full upright image before panel rectification.
    ///
    /// - Returns: a `SurfaceMap` in normalized panel space.
    /// - Throws: `SurfaceUnderstandingError`.
    public func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        fatalError("unimplemented — owned by Surface / Officers (integration)")
    }
}
