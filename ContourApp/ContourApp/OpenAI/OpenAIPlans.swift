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
    /// Includes getting a token. The server allows itself 8 s, but /plan's median is about 2 s.
    static let timeout: Duration = .seconds(6)
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
}

nonisolated extension CookTimePlan {
    /// A server plan in the form the step loop walks. The sentence is built here from
    /// the same names as the steps, not taken from the model, so what the user hears
    /// is what they'll be guided through.
    init(serverSteps: [SurfaceMap.Button], in map: SurfaceMap) {
        let start = TargetMatcher().match("start", in: map)?.button
        let steps = serverSteps.map { button in
            let label = button.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Step(name: button.id == start?.id ? "Start" : label.isEmpty ? "that key" : label, button: button)
        }
        let names = steps.map(\.name)
        let say = names.count > 1
            ? "Press \(names.dropLast().joined(separator: ", ")), then \(names[names.count - 1])."
            : "Press \(names.joined())."
        self.init(steps: steps, say: say, warning: nil)
    }
}
