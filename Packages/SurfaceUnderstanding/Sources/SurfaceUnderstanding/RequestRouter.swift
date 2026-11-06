//
//  RequestRouter.swift
//  SurfaceUnderstanding
//
//  Created by Asav Gupta on 11/5/26.
//

import ContourCore
import Foundation

/// What the user asked for.
public enum RoutedRequest: Hashable, Sendable {
    case plan(TaskPlan)     // press a button, or several in order
    case readDisplay        // "what does it say?"
    case listButtons        // "what buttons are there?"
    case help(String)       // "what can I say?", with a sentence to read out
}

public struct RequestRouter: Sendable {
    private let planner: TaskPlanner

    /// `service: nil` means offline.
    public init(service: (any PlanService)?, timeout: Duration = .seconds(3)) {
        planner = TaskPlanner(service: service, timeout: timeout)
    }

    public func route(_ request: String, in map: SurfaceMap) async -> RoutedRequest {
        let said = Self.normalized(request)
        if Self.readDisplay.contains(said) { return .readDisplay }
        if Self.listButtons.contains(said) { return .listButtons }
        if Self.help.contains(said) { return .help(Self.helpSentence) }

        // A cook time, unless it's about another key, like Add 30 Sec or a timer.
        let words = Set(said.split(separator: " ").map(String.init))
        if words.isDisjoint(with: Self.plannerWords), !request.contains("+"),
           let time = CookTime(request) {
            return .plan(cookPlan(time, in: map))
        }
        return .plan(await planner.plan(request, in: map))
    }

    /// Time Cook, the digits, then Start. No steps if a key is missing.
    private func cookPlan(_ time: CookTime, in map: SurfaceMap) -> TaskPlan {
        guard time.minutes * 60 + time.seconds <= 3600 else {
            return TaskPlan(steps: [], say: "That's too long to set. Try 60 minutes or less.")
        }
        guard let timeCook = TargetMatcher().match("time cook", in: map)?.button else {
            return TaskPlan(steps: [], say: "I can't find Time Cook on this panel. Try scanning again.")
        }
        // Exact labels, so "1" can't land on a key like Add 1 Min.
        let digits = time.digits.compactMap { digit in map.buttons.first { $0.label == digit } }
        guard digits.count == time.digits.count,
              let start = TargetMatcher().match("start", in: map)?.button else {
            return TaskPlan(steps: [], say: "I can't find the number keys on this panel. Try scanning again.")
        }
        return TaskPlan(steps: [timeCook] + digits + [start],
                        say: "Press \(timeCook.label ?? "Time Cook"), then \(time.digits.joined(separator: ", ")), then Start.")
    }

    /// Lowercased, punctuation and ButtonLookup's fillers dropped.
    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !TaskPlanner.fillers.contains($0) }
            .joined(separator: " ")
    }

    private static func phrases(_ list: String...) -> Set<String> { Set(list.map(normalized)) }

    private static let readDisplay = phrases("what does it say", "what does the display say", "what's on the display",
                                             "what's on the screen", "read the display", "read the screen")
    private static let listButtons = phrases("what buttons are there", "which buttons are there", "what can i press",
                                             "list the buttons", "what are the buttons")
    private static let help = phrases("help", "what can i say", "what can i ask", "what do i say")

    /// Words that mean another key, so the request goes to the planner.
    private static let plannerWords: Set = ["add", "plus", "timer", "clock", "defrost", "popcorn", "power", "delay"]

    private static let helpSentence =
        "You can ask me to press a button, set a cook time like 2 minutes, read the display, or list the buttons."
}
