//
//  GuidanceFlow.swift
//  ContourUI — Experience / App Flow
//
//  Weeks 2–3 deliverable: "Basic target selection and guidance flow."
//
//  The state machine from "app opened" to "finger on the button". Every
//  transition here is a moment where a user who cannot see the screen has to be
//  told what just happened and what to do next — so this file is as much an
//  accessibility document as a controller.
//
//  WHAT THIS DOES NOT DO
//  It never calls Surface Understanding, Tracking, or ContourFeedback directly.
//  ContourUI depends on ContourCore
//  and nothing else. The flow says "I have a photo" and "the user chose this
//  button"; ContourApp does the rest and hands results back.
//

import ContourCore
import Foundation

/// Where the user is in the interaction.
///
/// Each case is a thing that has to be announced. If you add a case, you owe it
/// an announcement — a silent state change is a user stranded.
public enum GuidanceFlowStage: Hashable, Sendable {

    /// Nothing started yet.
    case idle

    /// Camera is up; the user is trying to get the panel into frame.
    ///
    /// The hard one. The user cannot see the preview. Weeks 6–7 call this out
    /// explicitly as "camera positioning instructions".
    case acquiringPanel

    /// A photo has been taken and detection is running.
    case detecting

    /// A panel was read; the user is choosing which control they want.
    case selectingTarget(SurfaceMap)

    /// A target is chosen and guidance is live.
    case guiding(SurfaceMap.Button)

    /// The interaction ended, one of four ways.
    case finished(OutcomeSignal)
}

/// Drives the interaction from launch to outcome.
public struct GuidanceFlow: Sendable {

    public init() {}

    /// The stage the flow is in right now.
    public func currentStage() async -> GuidanceFlowStage {
        fatalError("unimplemented — owned by Experience / App Flow")
    }

    /// Move the flow to `stage`, announcing the transition.
    ///
    /// Every transition is announced. A user who cannot see the screen has no
    /// other way to know the app moved on.
    public func advance(to stage: GuidanceFlowStage) async {
        fatalError("unimplemented — owned by Experience / App Flow")
    }

    /// What to tell the user when the flow enters `stage`.
    ///
    /// Pure and synchronous on purpose — this is the accessibility script, and
    /// it is the part a test can pin. A test asserting that every
    /// `GuidanceFlowStage` produces a non-empty announcement is worth writing
    /// before any UI exists.
    public func announcement(for stage: GuidanceFlowStage) -> String {
        fatalError("unimplemented — owned by Experience / App Flow")
    }
}
