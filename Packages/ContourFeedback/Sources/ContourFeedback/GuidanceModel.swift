//
//  GuidanceModel.swift
//  ContourFeedback — Experience / Haptics
//
//  Weeks 2–3 deliverable: "Run the guidance model bake-off (Week 2) and pick one."
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  THIS IS A GATE, NOT A TASK.                                             │
//  │                                                                          │
//  │  "End of Week 2: interfaces and coordinate convention frozen. Guidance    │
//  │  model chosen from the bake-off."                                        │
//  │                                                                          │
//  │  Whatever you pick here, the rest of the project builds around. Run the   │
//  │  bake-off in the Harness in Week 2 — you do not need working tracking to  │
//  │  compare models, and waiting for it costs you the gate.                   │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  A "guidance model" is the mapping from a GuidanceVector to what the user
//  perceives. The candidates below are a starting list, not the answer. Add,
//  remove, and rename freely — this enum is yours and nobody outside this
//  package reads it.
//
//  COORDINATES: `direction` is panel space — +dy is DOWN.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A candidate way of turning guidance into perception, for the Week 2 bake-off.
///
/// Deliberately shallow — the point of the bake-off is to feel these, not to
/// read about them. Build each one behind `GuidanceModel`, run them through the
/// Harness blindfolded, and delete the ones that lose.
public enum GuidanceModelKind: String, Hashable, Sendable, CaseIterable {

    /// Pulse rate encodes distance; nothing encodes direction. The user sweeps
    /// and follows the warmth. Simplest to build, slowest to use.
    case hotColdProximity

    /// Distinct haptic signatures for up / down / left / right, fired as
    /// discrete corrections. Precise, but chatty at close range.
    case discreteDirectional

    /// Continuous stereo audio panning for left-right plus pitch for up-down,
    /// with haptics reserved for proximity and arrival.
    case continuousAudioField

    /// Spoken corrections — "left a bit, down". Immediately understandable,
    /// but slow and it occupies the channel the user needs for the room.
    case spokenCorrections
}

/// The thing a guidance model must be able to do.
///
/// One state in, one perceptual frame out. Keeping this separate from
/// `LiveFeedbackEngine` is what lets you swap models during the bake-off without
/// rewiring anything.
public protocol GuidanceModel: Sendable {

    /// Which candidate this is.
    var kind: GuidanceModelKind { get }

    /// Render one moment of guidance.
    ///
    /// Must return promptly — it is called at camera rate. Start effects, do not
    /// await them.
    func render(_ state: GuidanceState) async
}

/// The model chosen at the end of Week 2.
///
/// Set this once the bake-off is decided, and record *why* in the PR. Every
/// later argument about feel starts from this decision.
public enum ChosenGuidanceModel {

    /// `nil` until the Week 2 gate. CI does not enforce that — your lead does.
    public static let kind: GuidanceModelKind? = nil
}
