//
//  TraceReplay.swift
//  Tracking
//

import Foundation

/// Feeds a recorded trace through HybridAlignment the way the live loop does:
/// one frame at a time, in order, with the recorded timestamps. The policy's
/// freshness and rejection rules see the original timing, unchanged.
struct TraceReplay {
    /// What the policy reported after one frame.
    struct Step: Hashable, Sendable {
        var index: Int
        /// Seconds since the trace's first frame.
        var offset: TimeInterval
        var source: HybridTrackingDiagnostics.Source
        var mode: HybridTrackingDiagnostics.Mode
        var calibrationReady: Bool
        var resetCount: Int
        var lastResetReason: String?
        var message: String
    }

    enum Change: Hashable, Sendable {
        case source(HybridTrackingDiagnostics.Source)
        case mode(HybridTrackingDiagnostics.Mode)
        case calibrationReady(Bool)
        case reset(reason: String?)
    }

    /// A step where something changed. The first step reports its source and mode.
    struct Event: Hashable, Sendable {
        var index: Int
        var offset: TimeInterval
        var change: Change
    }

    private(set) var steps: [Step] = []
    private(set) var events: [Event] = []

    init(_ trace: CalibrationTrace, alignment: HybridAlignment = HybridAlignment()) throws {
        try trace.validate()
        guard let start = trace.frames.first?.timestamp else { return }
        var alignment = alignment
        var previousReference: UUID??

        for frame in trace.frames {
            // A replaced reference is invisible to the snapshot; the live
            // coordinator reports it through invalidate, so replay does too.
            if let previousReference, previousReference != frame.referenceID {
                alignment.invalidate()
            }
            previousReference = frame.referenceID

            let (visual, world) = try frame.inputs()
            guard let diagnostics = alignment.update(visual: visual, world: world).hybridDiagnostics else {
                throw TraceReplayError.missingDiagnostics(index: frame.index)
            }
            record(Step(index: frame.index, offset: frame.timestamp.timeIntervalSince(start),
                        source: diagnostics.source, mode: diagnostics.mode,
                        calibrationReady: diagnostics.calibrationReady,
                        resetCount: diagnostics.resetCount, lastResetReason: diagnostics.lastResetReason,
                        message: diagnostics.message))
        }
    }

    private mutating func record(_ step: Step) {
        let previous = steps.last
        func event(_ change: Change) {
            events.append(Event(index: step.index, offset: step.offset, change: change))
        }
        // Counted rather than read from didReset, so a reset raised by
        // invalidate between frames is not lost.
        if step.resetCount > (previous?.resetCount ?? 0) { event(.reset(reason: step.lastResetReason)) }
        if step.source != previous?.source { event(.source(step.source)) }
        if step.mode != previous?.mode { event(.mode(step.mode)) }
        if step.calibrationReady != (previous?.calibrationReady ?? false) {
            event(.calibrationReady(step.calibrationReady))
        }
        steps.append(step)
    }
}

enum TraceReplayError: Error, Equatable {
    /// The policy returned an observation without its diagnostics.
    case missingDiagnostics(index: Int)
}
