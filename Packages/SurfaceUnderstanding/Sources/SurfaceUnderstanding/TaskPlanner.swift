//
//  TaskPlanner.swift
//  SurfaceUnderstanding — Surface / Target Matching
//
//  Turns "cook for a minute and a half" into 1, 3, 0, Start. Asks the plan
//  server, and falls back to TargetMatcher's one key whenever it can't help.
//

import ContourCore
import Foundation

/// The keys to press, in order, and what to tell the user.
public struct TaskPlan: Hashable, Sendable {
    public var steps: [SurfaceMap.Button]
    public var say: String

    public init(steps: [SurfaceMap.Button], say: String) {
        self.steps = steps
        self.say = say
    }
}

// MARK: - (POST {base}/plan)

/// What goes to the server: the request and every labelled button.
public struct PlanRequest: Codable, Sendable, Hashable {
    public struct Button: Codable, Sendable, Hashable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var request: String
    public var buttons: [Button]

    public init(request: String, buttons: [Button]) {
        self.request = request
        self.buttons = buttons
    }
}

/// The server's answer: button ids in order, and a sentence to say.
public struct PlanResponse: Codable, Sendable, Hashable {
    public var steps: [String]
    public var say: String

    public init(steps: [String], say: String) {
        self.steps = steps
        self.say = say
    }
}

/// Anything that can plan presses: the live server, or a fake in tests.
public protocol PlanService: Sendable {
    func plan(_ request: PlanRequest) async throws -> PlanResponse
}

// MARK: - Live service

/// Talks to the plan server. The server answers 401 to any request without a
/// Firebase App Check token, so the app passes in a closure that returns one.
/// Firebase stays in ContourApp; this package only sends the header.
public struct LivePlanService: PlanService {
    public let baseURL: URL
    private let appCheckToken: (@Sendable () async throws -> String)?

    public init(baseURL: URL, appCheckToken: (@Sendable () async throws -> String)? = nil) {
        self.baseURL = baseURL
        self.appCheckToken = appCheckToken
    }

    public func plan(_ request: PlanRequest) async throws -> PlanResponse {
        var urlRequest = URLRequest(url: baseURL.appending(path: "plan"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let appCheckToken {
            urlRequest.setValue(try await appCheckToken(), forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        // Anything but a 200 is a failure.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // Throws if the JSON doesn't decode.
        return try JSONDecoder().decode(PlanResponse.self, from: data)
    }
}

// MARK: - Planner

public struct TaskPlanner: Sendable {
    private let service: (any PlanService)?
    private let timeout: Duration

    /// `service: nil` means offline: always use the matcher.
    public init(service: (any PlanService)?, timeout: Duration = .seconds(3)) {
        self.service = service
        self.timeout = timeout
    }

    /// The presses for `request` on `map`. Never fails; falls back to one key.
    public func plan(_ request: String, in map: SurfaceMap) async -> TaskPlan {
        // Only labelled buttons go out. Ids change every scan, so a plan
        // only works on the map it came from.
        let sent = map.buttons.filter { $0.label != nil }
        let body = PlanRequest(
            request: request,
            buttons: sent.map { PlanRequest.Button(id: $0.id.uuidString, label: $0.label ?? "") }
        )

        if let service,
           let response = await ask(service, body),
           let plan = checked(response, sent: sent) {
            return plan
        }
        return fallback(request, in: map)
    }

    /// The service's answer, or nil if it threw or lost the race to `timeout`.
    private func ask(_ service: any PlanService, _ body: PlanRequest) async -> PlanResponse? {
        let timeout = timeout
        return await withTaskGroup(of: PlanResponse?.self) { group in
            group.addTask { try? await service.plan(body) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            // First one back wins; cancel the other.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The plan if every step is an id we sent and `say` isn't empty.
    /// Repeats are fine (1, 1, 0). `steps: []` with a sentence passes through.
    private func checked(_ response: PlanResponse, sent: [SurfaceMap.Button]) -> TaskPlan? {
        guard !response.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let byID = Dictionary(sent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var steps: [SurfaceMap.Button] = []
        for step in response.steps {
            guard let id = UUID(uuidString: step), let button = byID[id] else { return nil }
            steps.append(button)
        }
        return TaskPlan(steps: steps, say: response.say)
    }

    /// Same as ButtonLookup today: drop fillers, ask TargetMatcher once.
    private func fallback(_ request: String, in map: SurfaceMap) -> TaskPlan {
        let named = request.split(whereSeparator: \.isWhitespace).filter { word in
            !Self.fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        guard let button = TargetMatcher().match(named.joined(separator: " "), in: map)?.button else {
            return TaskPlan(steps: [], say: "I couldn't find that on this panel.")
        }
        return TaskPlan(steps: [button], say: "Press \(button.label ?? "that button").")
    }

    /// Copied from ButtonLookup.swift lines 28-31. Keep the two in sync.
    private static let fillers: Set<String> = [
        "the", "a", "an", "please", "press", "push", "hit", "tap", "button", "to", "i", "want",
        "need", "can", "you", "find", "where", "is", "it", "me", "take", "guide",
    ]
}
