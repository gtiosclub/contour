import ContourCore
import Foundation
import HarnessConnectivity
import Observation
import UIKit

/// Phone-side controller exposed to the debug UI through SwiftUI's environment.
/// Uses temporary UIKit haptics until the Experience team implements live feedback.
@MainActor
@Observable
final class HarnessConnection {
    let peer = HarnessPeerConnection(role: .phone)
    private(set) var lastState: GuidanceState?
    private(set) var lastOutcome: OutcomeSignal?
    private(set) var feedbackEnabled = true
    private let feedback: any FeedbackEngine
    private var pendingStates: [GuidanceState] = []
    private var feedbackTask: Task<Void, Never>?

    // TODO: Integrate the Experience team's LiveFeedbackEngine here once its
    // haptics/audio methods are implemented. They currently contain fatalError stubs.
    init(feedback: any FeedbackEngine = HarnessTemporaryHaptics()) {
        self.feedback = feedback
        peer.onGuidance = { [weak self] state in
            self?.lastState = state
            if let outcome = state.outcome { self?.lastOutcome = outcome }
            if self?.feedbackEnabled == true { self?.enqueue(state) }
        }
        peer.onInterrupted = { [weak self] in
            guard let self else { return }
            let state = GuidanceState.outcome(.lostTracking, at: Date())
            self.lastState = state
            self.lastOutcome = .lostTracking
            self.pendingStates.removeAll()
            if self.feedbackEnabled { self.enqueue(state) }
        }
    }

    func start() { peer.start() }
    func stop() { peer.stop() }
    func reconnect() { peer.reconnect() }

    /// Continue receiving/inspecting states while pausing audible/haptic feedback.
    func setFeedbackEnabled(_ enabled: Bool) {
        guard enabled != feedbackEnabled else { return }
        feedbackEnabled = enabled
        pendingStates.removeAll()
        if enabled {
            // Resume current geometry, never replay an old terminal announcement.
            if peer.isReceiving, let state = lastState, state.outcome == nil { enqueue(state) }
        } else {
            enqueue(GuidanceState(timestamp: Date(), vector: nil))
        }
    }

    private func enqueue(_ state: GuidanceState) {
        // Keep the latest geometry if playback is busy, while preserving outcome order.
        if state.outcome == nil, pendingStates.last?.outcome == nil, !pendingStates.isEmpty {
            pendingStates[pendingStates.count - 1] = state
        } else { pendingStates.append(state) }
        guard feedbackTask == nil else { return }
        feedbackTask = Task { [weak self] in
            guard let self else { return }
            while !self.pendingStates.isEmpty {
                let next = self.pendingStates.removeFirst()
                await self.feedback.present(next)
            }
            self.feedbackTask = nil
        }
    }
}

/// Bounded-memory stand-in: reception is observable above; this keeps no history.
struct HarnessConsoleFeedback: FeedbackEngine {
    nonisolated init() {}
    nonisolated func present(_ state: GuidanceState) async {
        print("[phone harness] \(state)")
    }
}

/// Temporary feedback for testing the Mac-to-phone connection on a real iPhone.
/// TODO: Replace this adapter with the real ContourFeedback haptics integration.
/// These simple pulses do not encode direction or proximity; audio is not wired yet.
@MainActor
final class HarnessTemporaryHaptics: FeedbackEngine {
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()
    private var lastPulseAt: TimeInterval = -.infinity

    func present(_ state: GuidanceState) async {
        if let outcome = state.outcome {
            lastPulseAt = -.infinity
            notification.notificationOccurred(outcome == .arrived ? .success : .warning)
            return
        }
        guard state.vector != nil else {
            // A neutral state stops feedback; there is no continuous effect to cancel.
            lastPulseAt = -.infinity
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Avoid flooding the haptic motor during rapid drag updates.
        guard now - lastPulseAt >= 0.12 else { return }
        lastPulseAt = now
        impact.impactOccurred()
    }
}
