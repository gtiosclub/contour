//
//  GuidancePresentation.swift
//  ContourUI — Experience / App Flow
//
//  What the guidance screen shows and offers for each moment of a guidance
//  session (#151). Policy only: no views, no layout, no styling, so the screen
//  can be redesigned without touching these rules.
//
//  The phase is read from the same `GuidanceState` the feedback engine is
//  given, so the screen and the speech/haptics cannot disagree about what
//  happened. In particular the screen never decides arrival for itself: a
//  finger at distance zero is `.holding` until the guidance system reports
//  `.arrived`.
//

import ContourCore
import Foundation

/// The distinct moments of a guidance session, as the screen represents them.
public enum GuidancePhase: Hashable, Sendable {

    /// Guidance is live and the finger still has to move.
    case guiding

    /// No usable guidance for this frame, and no loss has been reported yet.
    /// Short gaps land here; the screen stops showing a direction but nothing
    /// is announced.
    case searching

    /// The panel is tracked but no fingertip is detected, so there is no
    /// direction to give. Kept apart from `.searching` so the screen does not
    /// claim the panel is missing when only the finger is.
    case findingFinger

    /// The guidance system reported that tracking was lost. The session is
    /// still running and resumes if the panel comes back.
    case lostTracking

    /// The finger is on the target and the hold has not been confirmed yet.
    case holding

    /// The guidance system confirmed the completed hold.
    case arrived

    /// The requested control is not on this panel.
    case notFound

    /// Something was found, but not confidently enough to guide to.
    case lowConfidence

    /// Guidance could not start, with the reason to show.
    case cannotStart(String)

    /// The session ended without arriving: stopped, cancelled, or replaced.
    case stopped

    /// The phase a single guidance state represents.
    ///
    /// - Parameter fingerMissing: whether the frame behind `state` tracked the
    ///   panel but detected no fingertip. A state alone cannot tell this apart
    ///   from any other gap.
    public init(_ state: GuidanceState, fingerMissing: Bool = false) {
        if let outcome = state.outcome {
            switch outcome {
            case .arrived: self = .arrived
            case .lostTracking: self = .lostTracking
            case .notFound: self = .notFound
            case .lowConfidence: self = .lowConfidence
            }
            return
        }
        guard let vector = state.vector,
              vector.normalizedDistance.isFinite, vector.normalizedDistance >= 0,
              vector.direction.dx.isFinite, vector.direction.dy.isFinite else {
            self = fingerMissing && state.vector == nil ? .findingFinger : .searching
            return
        }
        self = vector.normalizedDistance == 0 ? .holding : .guiding
    }

    /// Tracking could not lock onto the panel. The pipeline's own error is
    /// worded for developers; the user only needs to know that waiting won't
    /// help and a new scan might. Spoken with the same words.
    public static let cannotLockOn = GuidancePhase.cannotStart(
        "Couldn't lock onto the panel. Scan again with the whole panel in view.")

    /// Whether a guidance session is still running in this phase.
    public var isActive: Bool {
        switch self {
        case .guiding, .searching, .findingFinger, .lostTracking, .holding: true
        case .arrived, .notFound, .lowConfidence, .cannotStart, .stopped: false
        }
    }
}

/// Something the user can do from the guidance screen.
public enum GuidanceAction: String, Hashable, Sendable, CaseIterable {

    /// End the running session.
    case stop

    /// Guide to the same control again.
    case retry

    /// Go back and pick a different control on the same panel.
    case chooseAnother

    /// Go back to the camera and scan the panel again.
    case scanAgain

    /// The button title, also used as its accessibility label.
    public var title: String {
        switch self {
        case .stop: "Stop"
        case .retry: "Try again"
        case .chooseAnother: "Choose another button"
        case .scanAgain: "Scan again"
        }
    }
}

/// The words and actions the guidance screen shows for one phase.
public struct GuidanceScreenContent: Hashable, Sendable {

    /// The large heading.
    public var title: String

    /// One sentence saying what is happening or what to do next.
    public var message: String

    /// The available actions, most useful first.
    public var actions: [GuidanceAction]

    /// - Parameters:
    ///   - phase: the current phase of the session.
    ///   - targetLabel: the selected control's label, or `nil` when it has none.
    public init(phase: GuidancePhase, targetLabel: String?) {
        let name = targetLabel ?? "the selected button"
        let heading = targetLabel ?? "Selected button"
        switch phase {
        case .guiding:
            title = heading
            message = "Move your finger toward \(name)."
            actions = [.stop]
        case .searching:
            title = heading
            message = "Looking for the panel."
            actions = [.stop]
        case .findingFinger:
            title = heading
            message = "Can't see your finger. Move it in front of the panel."
            actions = [.stop]
        case .lostTracking:
            title = "Lost the panel"
            message = "Point the camera at the panel again."
            actions = [.scanAgain, .stop]
        case .holding:
            title = heading
            message = "Hold here."
            actions = [.stop]
        case .arrived:
            title = "Reached \(name)"
            message = "Your finger is on \(name)."
            actions = [.chooseAnother, .scanAgain]
        case .notFound:
            title = "Not on this panel"
            message = "This panel doesn't have \(name)."
            actions = [.chooseAnother, .scanAgain]
        case .lowConfidence:
            title = "Not sure"
            message = "I'm not sure I can see \(name). Show the whole panel and scan again."
            actions = [.scanAgain, .chooseAnother]
        case .cannotStart(let reason):
            title = "Guidance couldn't start"
            message = reason
            actions = [.scanAgain, .chooseAnother]
        case .stopped:
            title = "Guidance stopped"
            message = "Try \(name) again, choose another button, or scan again."
            actions = [.retry, .chooseAnother, .scanAgain]
        }
    }

    /// What to announce when the session moves from `old` to `new`, or `nil`
    /// when nothing should be said.
    ///
    /// Announced once per change, never per frame. Short gaps and the
    /// guiding/holding boundary stay silent here: the feedback engine already
    /// speaks movement and hold instructions, and a finger resting on the edge
    /// of the target would otherwise announce on every crossing.
    public static func announcement(
        from old: GuidancePhase?,
        to new: GuidancePhase,
        targetLabel: String?
    ) -> String? {
        guard old != new else { return nil }
        switch new {
        case .searching, .findingFinger, .holding:
            return nil
        case .guiding:
            if let old, old == .holding || old == .searching || old == .findingFinger { return nil }
        case .lostTracking, .arrived, .notFound, .lowConfidence, .cannotStart, .stopped:
            break
        }
        return GuidanceScreenContent(phase: new, targetLabel: targetLabel).message
    }
}
