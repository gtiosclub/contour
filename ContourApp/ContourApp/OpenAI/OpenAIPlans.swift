//
//  OpenAIPlans.swift
//  ContourApp — throwaway OpenAI demo, not for merging
//
//  The plan server, only when AppCheck.local.plist is in the app. Without that file
//  there's no server at all and the app behaves as it always did.
//

import ContourCore
import Foundation
import SurfaceUnderstanding

nonisolated struct OpenAIPlans: Sendable {
    static let projectID = "contour-6b924"
    static let baseURL = URL(string: "https://us-central1-contour-6b924.cloudfunctions.net/api")!
    /// Includes getting a token. A cold server start plus OpenAI took 5.5 to 5.8 s on the server on Nov 5, so 6 s was too short.
    static let timeout: Duration = .seconds(12)
    /// A longer plan than any microwave needs is more likely the model going wrong.
    static let maxSteps = 8

    let planner: TaskPlanner
    let token: @Sendable () async throws -> String

    /// `nil` when the file isn't there. A file that's there but wrong still gives a
    /// planner, one that can't get a token, so the status line says what's wrong.
    static func fromBundle(_ bundle: Bundle = .main) -> OpenAIPlans? {
        guard let url = bundle.url(forResource: "AppCheck.local", withExtension: "plist") else { return nil }
        let token: @Sendable () async throws -> String
        do {
            let tokens = AppCheckDebugTokens(config: try AppCheckLocalConfig(contentsOf: url), projectID: projectID)
            token = { try await tokens.token() }
        } catch {
            token = { throw error }
        }
        let service = LivePlanService(baseURL: baseURL, appCheckToken: token)
        return OpenAIPlans(planner: TaskPlanner(service: service, timeout: timeout), token: token)
    }

    /// Whether the server's sentence, sent with no steps, sounds like keys to press:
    /// a number or time, a word for pressing, or any word of a key on this panel.
    static func soundsLikeKeys(_ sentence: String, in map: SurfaceMap) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let said = words(sentence)
        let keys = map.buttons.reduce(into: Set<String>()) { $0.formUnion(words($1.label ?? "")) }
        return CookTime.mentionsATime(sentence) || !said.isDisjoint(with: keys) || !said.isDisjoint(with: pressing)
    }

    private static let pressing: Set<String> = ["press", "pressing", "push", "pushing", "tap", "tapping", "hit"]
}

nonisolated extension CookTimePlan {
    /// A server plan in the form the step loop walks, held to the phone plan's rules:
    /// one clear key for every step, and its warning when there are numbers to press
    /// and no Time Cook key. The sentence is built here from the same names as the
    /// steps, not taken from the model, so what the user hears is what they'll be
    /// guided through.
    static func make(serverSteps: [SurfaceMap.Button], in map: SurfaceMap) -> Outcome {
        let start = TargetMatcher().match("start", in: map)?.button
        let steps = serverSteps.map { button in
            let label = trimmed(button.label)
            return Step(name: button.id == start?.id ? "Start" : label.isEmpty ? "that key" : label, button: button)
        }
        // Two keys read the same: the model picked one of them, and that's a guess.
        var unclear: [String] = []
        for step in steps where !unclear.contains(step.name) {
            let label = trimmed(step.button.label).lowercased()
            if only(in: map, where: { trimmed($0).lowercased() == label }) == nil { unclear.append(step.name) }
        }
        guard unclear.isEmpty else { return .missing(noClearKey(for: unclear)) }

        let names = steps.map(\.name)
        let say = names.count > 1
            ? "Press \(names.dropLast().joined(separator: ", ")), then \(names[names.count - 1])."
            : "Press \(names.joined())."
        let typesDigits = steps.contains { step in
            let label = trimmed(step.button.label)
            return !label.isEmpty && label.allSatisfy(\.isNumber)
        }
        let timeCook = only(in: map, where: isTimeCook)
        return .plan(CookTimePlan(steps: steps, say: say, warning: typesDigits && timeCook == nil ? noTimeCook : nil))
    }

    private static func trimmed(_ label: String?) -> String {
        label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
