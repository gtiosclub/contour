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
//  TRANSITION TABLE
//  Anything not listed is illegal: `advanceIfLegal(to:)` returns false and the
//  stage does not change, and nothing is announced.
//
//      from              to                          why
//      ───────────────── ─────────────────────────── ───────────────────────────────
//      idle              acquiringPanel              the camera screen comes up
//      acquiringPanel    detecting                   the user pressed Scan panel
//      detecting         selectingTarget(map)        the panel was read
//      detecting         acquiringPanel              detection failed or was cancelled
//      detecting         finished(.lowConfidence)    a panel, but too unsure to use
//      selectingTarget   guiding(button)             the user chose a control
//      selectingTarget   acquiringPanel              rescan
//      selectingTarget   finished(.notFound)         the spoken control is not on the panel
//      guiding           finished(any outcome)       the session ended one of four ways
//      guiding           selectingTarget(map)        Stop: choose again on the same panel
//      finished          acquiringPanel              scan a new panel
//      finished          guiding(button)             guide again to the same target
//      finished          selectingTarget(map)        choose another control on the same panel
//      any stage         idle                        cancel (`cancel()`), e.g. app backgrounded
//
//  A stage never transitions to itself: a repeated advance is a bug upstream,
//  and announcing it twice would talk over the user.
//

import ContourCore
import Foundation
import Synchronization
import os

#if canImport(SwiftUI)
import SwiftUI
#endif

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

extension GuidanceFlowStage {

    /// The case without its payload, for the transition table and logging.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case idle, acquiringPanel, detecting, selectingTarget, guiding, finished
    }

    /// Which case this is, ignoring the map, button or outcome it carries.
    public var kind: Kind {
        switch self {
        case .idle: .idle
        case .acquiringPanel: .acquiringPanel
        case .detecting: .detecting
        case .selectingTarget: .selectingTarget
        case .guiding: .guiding
        case .finished: .finished
        }
    }
}

/// Drives the interaction from launch to outcome.
///
/// A value type that shares one reference-type store, so every copy of a flow
/// sees the same stage — hand copies to views and tasks freely.
public struct GuidanceFlow: Sendable {

    private let store: FlowStore
    private let announce: @Sendable (String) async -> Void

    /// A flow that announces through VoiceOver (a no-op on macOS).
    public init() {
        self.init(announce: GuidanceFlow.postVoiceOverAnnouncement)
    }

    /// A flow that speaks each transition through `announce`.
    ///
    /// The app injects its announcer here (VoiceOver when it is running, speech
    /// otherwise); tests inject a recorder.
    public init(announce: @escaping @Sendable (String) async -> Void) {
        self.store = FlowStore()
        self.announce = announce
    }

    /// The stage the flow is in right now.
    public func currentStage() async -> GuidanceFlowStage {
        store.stage
    }

    /// Move the flow to `stage`, announcing the transition.
    ///
    /// Every transition is announced. A user who cannot see the screen has no
    /// other way to know the app moved on. Illegal moves are ignored and logged;
    /// use `advanceIfLegal(to:)` to find out whether a move happened.
    public func advance(to stage: GuidanceFlowStage) async {
        await advanceIfLegal(to: stage)
    }

    /// Move the flow to `stage` if the transition table allows it, announcing it.
    ///
    /// - Returns: `true` if the flow moved; `false` if the move was illegal from
    ///   the current stage, in which case nothing changed and nothing was said.
    @discardableResult
    public func advanceIfLegal(to stage: GuidanceFlowStage) async -> Bool {
        guard let from = store.transition(to: stage) else {
            GuidanceFlow.log.debug(
                "Ignored illegal move to \(stage.kind.rawValue, privacy: .public) from \(store.stage.kind.rawValue, privacy: .public)"
            )
            return false
        }
        GuidanceFlow.log.debug(
            "\(from.kind.rawValue, privacy: .public) → \(stage.kind.rawValue, privacy: .public)"
        )
        await announce(announcement(for: stage))
        return true
    }

    /// Abandon whatever is happening and return to `.idle`. Legal from anywhere.
    ///
    /// - Returns: `true` if the flow moved; `false` if it was already idle.
    @discardableResult
    public func cancel() async -> Bool {
        await advanceIfLegal(to: .idle)
    }

    /// Every stage the flow enters, starting with the current one.
    ///
    /// For SwiftUI: `.task { for await stage in flow.stages() { … } }`. The stream
    /// ends when the consuming task is cancelled. Each call is an independent
    /// subscription and sees every later transition, in order.
    public func stages() -> AsyncStream<GuidanceFlowStage> {
        store.subscribe()
    }

    /// Whether the transition table allows moving from `from` to `to`.
    public static func isLegal(from: GuidanceFlowStage, to: GuidanceFlowStage) -> Bool {
        if from == to { return false }
        switch (from, to) {
        case (_, .idle):
            return true
        case (.idle, .acquiringPanel),
             (.acquiringPanel, .detecting),
             (.detecting, .selectingTarget),
             (.detecting, .acquiringPanel),
             (.detecting, .finished(.lowConfidence)),
             (.selectingTarget, .guiding),
             (.selectingTarget, .acquiringPanel),
             (.selectingTarget, .finished(.notFound)),
             (.guiding, .finished),
             (.guiding, .selectingTarget),
             (.guiding, .acquiringPanel),   // Scan again, when tracking can't lock on
             (.finished, .acquiringPanel),
             (.finished, .guiding),
             (.finished, .selectingTarget):
            return true
        default:
            return false
        }
    }

    /// What to tell the user when the flow enters `stage`.
    ///
    /// Pure and synchronous on purpose — this is the accessibility script, and
    /// it is the part a test can pin. Written to be heard, not read: short,
    /// what just happened first, then what to do next.
    public func announcement(for stage: GuidanceFlowStage) -> String {
        switch stage {
        case .idle:
            return "Contour stopped."
        case .acquiringPanel:
            return "Point your phone at the panel, about a foot away. Then tap Scan panel, at the bottom of the screen."
        case .detecting:
            return "Reading the panel. Hold still."
        case .selectingTarget(let map):
            switch map.buttons.count {
            case 0:
                return "No controls found. Scan again."
            case 1:
                return "Found 1 control. Say a button, or swipe right to choose it."
            case let count:
                return "Found \(count) controls. Say a button, or swipe right to choose one."
            }
        case .guiding(let button):
            return "Guiding you to \(PanelLayout.spokenName(for: button)). Move your finger slowly. Vibration speeds up as you get closer."
        case .finished(.arrived):
            return "You're on it. Press now."
        case .finished(.lostTracking):
            return "Lost sight of the panel. Point the phone back at it, then tap Guide again."
        case .finished(.notFound):
            return "That button isn't on this panel. Choose another, or scan again."
        case .finished(.lowConfidence):
            return "Couldn't read the panel clearly. Add light, hold steady, and scan again."
        }
    }

    // MARK: VoiceOver

    private static let log = Logger(subsystem: "edu.gatech.contour", category: "GuidanceFlow")

    /// Posts `text` as a high-priority VoiceOver announcement. No-op on macOS,
    /// and harmless when VoiceOver is off.
    @Sendable
    public static func postVoiceOverAnnouncement(_ text: String) async {
        #if os(iOS) && canImport(SwiftUI)
        await MainActor.run {
            var message = AttributedString(text)
            message.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(message).post()
        }
        #endif
    }
}

// MARK: - Store

/// The shared, lock-protected backing store behind every copy of a flow.
private final class FlowStore: Sendable {

    private struct State {
        var stage: GuidanceFlowStage = .idle
        var subscribers: [UUID: AsyncStream<GuidanceFlowStage>.Continuation] = [:]
    }

    private let state = Mutex(State())

    var stage: GuidanceFlowStage {
        state.withLock { $0.stage }
    }

    /// Moves to `stage` if legal, telling subscribers. Returns the stage it left.
    func transition(to stage: GuidanceFlowStage) -> GuidanceFlowStage? {
        state.withLock { state in
            let from = state.stage
            guard GuidanceFlow.isLegal(from: from, to: stage) else { return nil }
            state.stage = stage
            // Yielding never blocks, so it is safe under the lock — and doing it
            // here keeps subscribers in exactly the order transitions happened.
            for continuation in state.subscribers.values { continuation.yield(stage) }
            return from
        }
    }

    func subscribe() -> AsyncStream<GuidanceFlowStage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GuidanceFlowStage>.makeStream()
        state.withLock { state in
            continuation.yield(state.stage)
            state.subscribers[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    deinit {
        state.withLock { state in
            state.subscribers.values.forEach { $0.finish() }
        }
    }
}
