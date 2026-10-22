//
//  TaskPlannerTests.swift
//  SurfaceUnderstanding
//
//  Created by Asav Gupta on 10/22/26.
//  TaskPlanner against a fake server, and the fallback when it can't help.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

/// Stands in for the server. Answers from a table of request -> labels and
/// turns labels into the ids it was sent, so it can only use ids it got.
struct FakePlanService: PlanService {
    struct FakeError: Error {}

    var table: [String: (labels: [String], say: String)] = [
        "cook for a minute and a half": (["1", "3", "0", "Start/Pause"], "Press 1, 3, 0, then Start."),
        "set it for 30 seconds": (["Add 30 Sec"], "Press Add 30 Sec."),
        "start": (["Start/Pause"], "Press Start."),
    ]
    var delay: Duration? = nil   // sleep before answering
    var fails = false            // throw instead of answering
    var madeUpID = false         // add an id that was never sent

    func plan(_ request: PlanRequest) async throws -> PlanResponse {
        if let delay { try await Task.sleep(for: delay) }
        if fails { throw FakeError() }

        guard let answer = table[request.request] else {
            return PlanResponse(steps: [], say: "I can't do that on this panel.")
        }
        var steps = answer.labels.compactMap { label in
            request.buttons.first { $0.label == label }?.id
        }
        if madeUpID { steps.append(UUID().uuidString) }
        return PlanResponse(steps: steps, say: answer.say)
    }
}

private let microwave = RealPanelLabels.map("hand-labelled microwave-01.jpg")

@Suite("Task planning")
struct TaskPlannerTests {

    @Test("a minute and a half plans 1, 3, 0, Start/Pause")
    func minuteAndAHalf() async {
        let plan = await TaskPlanner(service: FakePlanService()).plan("cook for a minute and a half", in: microwave)
        #expect(plan.steps.map(\.label) == ["1", "3", "0", "Start/Pause"])
        #expect(plan.say == "Press 1, 3, 0, then Start.")
    }

    @Test("30 seconds plans Add 30 Sec alone, only through the server")
    func thirtySeconds() async {
        let plan = await TaskPlanner(service: FakePlanService()).plan("set it for 30 seconds", in: microwave)
        #expect(plan.steps.map(\.label) == ["Add 30 Sec"])

        // Offline the matcher can't find it.
        let offline = await TaskPlanner(service: nil).plan("set it for 30 seconds", in: microwave)
        #expect(offline.steps.isEmpty)
    }

    @Test("a made-up id falls back to the matcher")
    func madeUpIDFallsBack() async {
        let plan = await TaskPlanner(service: FakePlanService(madeUpID: true)).plan("start", in: microwave)
        #expect(plan.steps.map(\.label) == ["Start/Pause"])
        #expect(plan.say == "Press Start/Pause.")   // the fallback's sentence, not the fake's
    }

    @Test("a slow server falls back, quickly")
    func slowFallsBack() async {
        let planner = TaskPlanner(service: FakePlanService(delay: .seconds(1)), timeout: .milliseconds(100))
        let start = ContinuousClock.now
        let plan = await planner.plan("start", in: microwave)
        let elapsed = ContinuousClock.now - start

        #expect(plan.steps.map(\.label) == ["Start/Pause"])
        #expect(elapsed < .milliseconds(500))
    }

    @Test("no service or a throwing one gives the key ButtonLookup finds today")
    func offlineAndThrowing() async {
        let services: [(any PlanService)?] = [nil, FakePlanService(fails: true)]
        for service in services {
            let plan = await TaskPlanner(service: service).plan("press start please", in: microwave)
            #expect(plan.steps.map(\.label) == ["Start/Pause"])
            #expect(plan.say == "Press Start/Pause.")
        }
    }

    @Test("the wire format matches the server contract")
    func wireFormat() throws {
        // Response JSON from the issue decodes.
        let json = #"{"steps": ["<button id>", "<button id>", "<button id>", "<button id>"], "say": "Press 1, 3, 0, then Start."}"#
        let response = try JSONDecoder().decode(PlanResponse.self, from: Data(json.utf8))
        #expect(response.steps.count == 4)
        #expect(response.say == "Press 1, 3, 0, then Start.")

        // Request encodes with request, buttons, id, label.
        let request = PlanRequest(request: "cook for a minute and a half",
                                  buttons: [PlanRequest.Button(id: "abc", label: "1")])
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        #expect(object["request"] as? String == "cook for a minute and a half")
        let buttons = try #require(object["buttons"] as? [[String: Any]])
        #expect(buttons.first?["id"] as? String == "abc")
        #expect(buttons.first?["label"] as? String == "1")
    }
}
