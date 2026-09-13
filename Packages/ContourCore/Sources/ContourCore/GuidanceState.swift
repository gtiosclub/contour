//
//  GuidanceState.swift
//  ContourCore
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  DRAFT — FROZEN END OF WEEK 2                                            │
//  │  Changes after the freeze require sign-off from all four team leads.     │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  Consumed by: Team 3 (ContourFeedback). This is the ONLY thing Team 3 reads.
//
//  `vector` is in NORMALIZED PANEL SPACE:
//  +dx is rightward, +dy is DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import Foundation

// MARK: - OutcomeSignal

/// A terminal event worth telling the user about.
///
/// Exactly four cases. This enum is the reason Team 3 can build its whole haptic
/// and audio vocabulary before Teams 1 and 2 have working code: there are four
/// things that can happen, and that list is closed.
///
/// Adding a fifth case is a `ContourCore` change — after the Week 2 freeze it
/// needs all four leads, because every `switch` in the app has to grow a branch.
public enum OutcomeSignal: String, Hashable, Sendable, Codable, CaseIterable {

    /// The fingertip reached the target. The one happy ending.
    case arrived

    /// Tracking dropped and has not come back. Guidance cannot continue until
    /// the user re-aims the camera.
    case lostTracking

    /// The requested control is not on this panel — the user asked for "defrost"
    /// and there is no defrost button. Distinct from `lostTracking`: nothing is
    /// broken, the answer is just no.
    case notFound

    /// Something was found, but not confidently enough to guide a finger to it.
    /// The user should be told to try again rather than trusted with a guess.
    case lowConfidence
}

// MARK: - GuidanceVector

/// Which way the finger has to move, and how far it has to go.
///
/// Split into direction and distance on purpose: Team 3's haptics encode
/// *direction* and its audio encodes *proximity*, and neither wants to do
/// trigonometry at 60 Hz.
public struct GuidanceVector: Hashable, Sendable, Codable {

    /// Unit-length direction from the fingertip toward the target, in panel
    /// space. `+dx` is rightward, `+dy` is **downward**.
    ///
    /// Always normalized — read `normalizedDistance` for magnitude. When the
    /// finger is exactly on target this is `.zero`, which is the one case where
    /// it is not unit length.
    public var direction: PanelVector

    /// How far the fingertip is from the target, `0...1`.
    ///
    /// `0` is dead on target. `1` is the far corner of the panel. Normalized
    /// against the panel's diagonal so that feedback intensity means the same
    /// thing on a microwave and on a lift control plate.
    ///
    /// Can exceed `1` when the finger is off the panel entirely.
    public var normalizedDistance: Double

    public init(direction: PanelVector, normalizedDistance: Double) {
        self.direction = direction
        self.normalizedDistance = normalizedDistance
    }

    /// Finger is on the target: no direction, no distance.
    public static let onTarget = GuidanceVector(
        direction: .zero,
        normalizedDistance: 0
    )
}

// MARK: - GuidanceState

/// Everything the feedback layer needs to know, right now.
///
/// One value, one moment. `GuidanceState` is deliberately not a stream type and
/// not a state machine — Team 3 receives these one at a time through
/// `FeedbackEngine.present(_:)` and decides for itself what to do with the
/// history.
///
/// Geometry is in normalized panel space. See `COORDINATES.md`.
public struct GuidanceState: Hashable, Sendable, Codable {

    /// When this state was computed.
    public var timestamp: Date

    /// Where the target is, relative to the fingertip.
    ///
    /// `nil` means guidance cannot currently be computed — no fingertip, no
    /// target selected, or tracking is lost. When this is `nil`, `outcome` is
    /// usually the interesting field.
    public var vector: GuidanceVector?

    /// A terminal event, if one just happened.
    ///
    /// `nil` is the common case and means "still guiding, nothing to announce".
    /// Non-`nil` means the interaction reached an end state — Team 3 plays the
    /// corresponding signal.
    public var outcome: OutcomeSignal?

    public init(
        timestamp: Date,
        vector: GuidanceVector?,
        outcome: OutcomeSignal? = nil
    ) {
        self.timestamp = timestamp
        self.vector = vector
        self.outcome = outcome
    }

    /// A state carrying only a terminal event and no geometry.
    public static func outcome(_ outcome: OutcomeSignal, at timestamp: Date) -> GuidanceState {
        GuidanceState(timestamp: timestamp, vector: nil, outcome: outcome)
    }

    /// Whether this state ends the interaction.
    public var isTerminal: Bool { outcome != nil }
}
