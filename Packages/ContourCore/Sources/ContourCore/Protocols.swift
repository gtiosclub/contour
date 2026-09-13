//
//  Protocols.swift
//  ContourCore
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  DRAFT — FROZEN END OF WEEK 2                                            │
//  │  Changes after the freeze require sign-off from all four team leads.     │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  Three protocols, one per producing team. Each team ships a type conforming to
//  its own protocol and never imports another team's package. `ContourApp` and
//  `Harness` are the only places the three meet.
//
//      Team 1  SurfaceUnderstanding  ──▶  SurfaceMap
//      Team 2  TrackingSource        ──▶  AsyncStream<TrackingFrame>
//      Team 3  FeedbackEngine        ◀──  GuidanceState
//      Team 4  ContourUI             ──▶  PanelPhoto, target selection
//
//  Async/await and Sendable throughout. No completion handlers, no delegates.
//

import Foundation

// MARK: - Team 1

/// Turns a photo of a control panel into a `SurfaceMap`.
///
/// Owned by **Team 1 — SurfaceUnderstanding**.
///
/// Positions in the returned map are in normalized panel space: `(0, 0)`
/// top-left, `(1, 1)` bottom-right, `y` down. See `COORDINATES.md`.
///
/// - Note: The `SurfaceUnderstanding` *package* has the same name as this
///   protocol. Inside that package, plain `SurfaceUnderstanding` resolves to the
///   module, so conformances there must spell it `ContourCore.SurfaceUnderstanding`.
///   Every other package can use the bare name.
public protocol SurfaceUnderstanding: Sendable {

    /// Detect the controls on the panel in `photo`.
    ///
    /// A panel found with poor confidence is a **successful** return with a low
    /// `SurfaceMap.confidence`, not a thrown error. Throw only when there is no
    /// answer at all.
    ///
    /// - Throws: `SurfaceUnderstandingError`.
    func surfaceMap(from photo: PanelPhoto) async throws -> SurfaceMap
}

// MARK: - Team 2

/// Emits a live stream of spatial state: where the panel is, where the finger is.
///
/// Owned by **Team 2 — Tracking**.
///
/// Fingertip positions are in normalized panel space: `(0, 0)` top-left, `(1, 1)`
/// bottom-right, `y` down. See `COORDINATES.md`.
public protocol TrackingSource: Sendable {

    /// Start tracking and return the stream of frames.
    ///
    /// The stream finishes when tracking is torn down. Cancelling the consuming
    /// task stops the source — a conformance must clean up on
    /// `AsyncStream.onTermination`.
    ///
    /// Frames must keep flowing while quality is `.lost`; emit
    /// `TrackingFrame.lost(at:)` rather than going silent, so consumers can tell
    /// "no finger" from "no source".
    ///
    /// Calling this more than once is a programmer error unless a conformance
    /// documents otherwise.
    func frames() -> AsyncStream<TrackingFrame>
}

// MARK: - Team 3

/// Turns guidance into something the user can feel, hear, or be told.
///
/// Owned by **Team 3 — ContourFeedback**.
///
/// This is the end of the pipeline: it consumes and returns nothing. A
/// conformance owns haptics, audio, and speech, and decides for itself how to
/// smooth, throttle, or ignore the states it is handed.
public protocol FeedbackEngine: Sendable {

    /// Present one moment of guidance.
    ///
    /// Called at camera rate while guiding, so this must return promptly —
    /// do not `await` the full duration of a haptic pattern or an utterance.
    /// Start the effect and return.
    ///
    /// A state with a non-`nil` `outcome` is terminal: the interaction has
    /// ended and the engine should play the corresponding signal.
    func present(_ state: GuidanceState) async
}
