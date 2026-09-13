//
//  PrintingFeedbackEngine.swift
//  ContourMocks
//
//  Team 3's stand-in. Prints each GuidanceState and keeps it, so the same object
//  serves as a console trace during development and as a spy in tests.
//
//  COORDINATES: `direction` is in normalized panel space — +dx right,
//  +dy DOWN. The rendered arrow below follows that convention: a direction of
//  (0, 1) prints as "down". See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A `FeedbackEngine` that prints what it is handed and remembers it.
///
/// An actor, so it is safe to hand to anything under Swift 6 strict concurrency
/// and safe to read back from a test while a stream is still running.
public actor PrintingFeedbackEngine: FeedbackEngine {

    /// Every state this engine has been given, oldest first.
    public private(set) var received: [GuidanceState] = []

    /// Whether to print. Turn it off in tests that only want the recording.
    private let isPrinting: Bool

    /// Prefix on each printed line, so two engines can be told apart.
    private let label: String

    public init(isPrinting: Bool = true, label: String = "feedback") {
        self.isPrinting = isPrinting
        self.label = label
    }

    public func present(_ state: GuidanceState) async {
        received.append(state)
        if isPrinting {
            print("[\(label)] \(Self.describe(state))")
        }
    }

    /// Drop the recording. Useful between phases of a test.
    public func reset() {
        received.removeAll()
    }

    /// The outcomes seen so far, in order.
    public var outcomes: [OutcomeSignal] {
        received.compactMap(\.outcome)
    }

    /// A one-line rendering of a state, e.g.
    /// `0.43 away, head down-right` or `outcome: arrived`.
    public static func describe(_ state: GuidanceState) -> String {
        var parts: [String] = []

        if let vector = state.vector {
            parts.append(String(format: "%.2f away", vector.normalizedDistance))
            parts.append("head \(compass(vector.direction))")
        } else {
            parts.append("no guidance")
        }

        if let outcome = state.outcome {
            parts.append("outcome: \(outcome.rawValue)")
        }

        return parts.joined(separator: ", ")
    }

    /// Turns a panel-space direction into a spoken compass word.
    ///
    /// Remember that `+dy` is **down**: `(0, 1)` is "down", not "up".
    public static func compass(_ direction: PanelVector) -> String {
        guard direction.magnitude > 0.001 else { return "nowhere — on target" }

        let vertical: String
        if direction.dy > 0.383 { vertical = "down" }
        else if direction.dy < -0.383 { vertical = "up" }
        else { vertical = "" }

        let horizontal: String
        if direction.dx > 0.383 { horizontal = "right" }
        else if direction.dx < -0.383 { horizontal = "left" }
        else { horizontal = "" }

        let words = [vertical, horizontal].filter { !$0.isEmpty }
        return words.isEmpty ? "steady" : words.joined(separator: "-")
    }
}
