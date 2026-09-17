//
//  LiveFeedbackEngine.swift
//  ContourFeedback — Experience / Outcome Signals & Harness
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  EMPTY ROOM. This is Experience's package, and nobody outside the team   │
//  │  commits here.                                                           │
//  │                                                                          │
//  │  Everything below is a stub. Replace the bodies, keep the signatures —   │
//  │  the signatures are ContourCore's contract and other teams are building  │
//  │  against them right now. Until this works, the app runs on               │
//  │  ContourMocks.PrintingFeedbackEngine.                                    │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  WHAT THIS PACKAGE OWES THE APP
//  Haptics, audio, speech, and the four outcome signals. Everything the user
//  perceives that is not on screen.
//
//  YOU ARE NOT BLOCKED BY ANYONE
//  This package reads exactly one type — GuidanceState — and that type is
//  already frozen-shaped and already mocked. You do not need a camera, a phone,
//  or Surface Understanding and Tracking to start. Run the Harness:
//
//      open Contour.xcworkspace     # then run the `Harness` scheme, My Mac
//
//  Sliders for the fingertip, a picker for tracking quality, four buttons for
//  the four outcomes. That is your blindfold rig. Use it from day one.
//
//  COORDINATES
//  `GuidanceState.vector.direction` is in normalized panel space: +dx is right,
//  +dy is DOWN. A direction of (0, -1) means "move the finger UP the panel".
//  Get this backwards and every user goes the wrong way.
//  See Packages/ContourCore/COORDINATES.md.
//
//  ONE PERFORMANCE NOTE
//  `present(_:)` is called at camera rate. Start an effect and return — never
//  await the full duration of a haptic pattern or an utterance.
//

import ContourCore
import Foundation

/// The real feedback engine. Experience builds this out.
public struct LiveFeedbackEngine: FeedbackEngine {

    public init() {}

    /// Present one moment of guidance as haptics, audio, and/or speech.
    ///
    /// A state with a non-`nil` `outcome` is terminal — play the corresponding
    /// signal for `arrived`, `lostTracking`, `notFound`, or `lowConfidence`.
    public func present(_ state: GuidanceState) async {
        fatalError("unimplemented — owned by Experience / Outcome Signals & Harness")
    }
}
