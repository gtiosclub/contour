//
//  LiveFeedbackEngine.swift
//  ContourFeedback — Experience / Outcome Signals & Harness
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  HAPTICS ONLY, for the MVP.                                              │
//  │                                                                          │
//  │  REAL     proximity pulses (ProximityHaptics) and the four outcome        │
//  │           signals (OutcomeAnnouncer), through HapticEngineManager.        │
//  │  FLAGGED  direction cues (DirectionalHaptics), off unless the             │
//  │           directionalHintsKey user default is on. Prototype for #119.     │
//  │  PENDING  directional audio and speech. DirectionalAudio and SpeechQueue  │
//  │           are still stubs, so this never calls them.                      │
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

/// The real feedback engine: guidance you feel.
public struct LiveFeedbackEngine: FeedbackEngine {

    /// `UserDefaults` key that turns on the direction cue prototype (#119).
    /// Read on every frame, so a debug toggle switches it between blindfold
    /// runs without rebuilding the pipeline. Off when unset.
    public static let directionalHintsKey = "contour.feedback.directionalHints"

    private let proximity: ProximityHaptics
    private let announcer: OutcomeAnnouncer
    private let direction: DirectionalHaptics
    private let directionalHints: @Sendable () -> Bool

    public init() {
        self.init(player: HapticPlayer()) {
            UserDefaults.standard.bool(forKey: Self.directionalHintsKey)
        }
    }

    init(player: HapticPlayer, directionalHints: @escaping @Sendable () -> Bool) {
        proximity = ProximityHaptics(player: player)
        announcer = OutcomeAnnouncer(player: player)
        direction = DirectionalHaptics(player: player)
        self.directionalHints = directionalHints
    }

    /// Present one moment of guidance as haptics, audio, and/or speech.
    ///
    /// A state with a non-`nil` `outcome` is terminal — play the corresponding
    /// signal for `arrived`, `lostTracking`, `notFound`, or `lowConfidence`.
    /// Otherwise the pulses follow the distance, and a state with no vector (no
    /// finger seen) goes quiet. With the direction flag on, a short cue now and
    /// then also says which way to move.
    public func present(_ state: GuidanceState) async {
        if let outcome = state.outcome {
            await direction.reset()
            await announcer.announce(outcome)
        } else {
            await proximity.play(for: state)
            if directionalHints() {
                await direction.play(for: state)
            }
        }
    }
}
