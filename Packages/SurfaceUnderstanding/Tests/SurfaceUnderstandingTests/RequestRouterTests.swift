//
//  RequestRouterTests.swift
//  SurfaceUnderstanding
//
//  Created by Asav Gupta on 11/5/26.
//

import ContourCore
import Testing
@testable import SurfaceUnderstanding

private let microwave = RealPanelLabels.map("hand-labelled microwave-01.jpg")
private let offline = RequestRouter(service: nil)

/// The plan inside a routed request, if it is one.
private func planOf(_ routed: RoutedRequest) -> TaskPlan? {
    if case .plan(let plan) = routed { return plan }
    return nil
}

/// The panel without the keys labelled `labels`.
private func microwave(without labels: String...) -> SurfaceMap {
    SurfaceMap(buttons: microwave.buttons.filter { !labels.contains($0.label ?? "") }, confidence: 1)
}

@Suite("Request routing")
struct RequestRouterTests {

    // MARK: Simple phrases

    @Test("display questions read the display", arguments: [
        "what does it say", "What does it say?", "what's on the display", "What’s on the screen?",
        "please read the display",
    ])
    func readDisplay(said: String) async {
        #expect(await offline.route(said, in: microwave) == .readDisplay)
    }

    @Test("button questions list the buttons", arguments: [
        "what buttons are there", "What can I press?", "which buttons are there", "list the buttons",
    ])
    func listButtons(said: String) async {
        #expect(await offline.route(said, in: microwave) == .listButtons)
    }

    @Test("help questions get a sentence to read out", arguments: [
        "help", "Help!", "what can I say", "what can i ask",
    ])
    func help(said: String) async {
        guard case .help(let sentence) = await offline.route(said, in: microwave) else {
            Issue.record("\(said) didn't route to help")
            return
        }
        #expect(!sentence.isEmpty)
    }

    // MARK: Cook times

    @Test("cook times press Time Cook, the digits, then Start", arguments: [
        ("a minute and a half", ["1", "3", "0"]),
        ("90 seconds", ["1", "3", "0"]),
        ("1:30", ["1", "3", "0"]),
        ("2 minutes", ["2", "0", "0"]),
        ("two and a half minutes", ["2", "3", "0"]),
        ("45 sec", ["4", "5"]),
        ("half a minute", ["3", "0"]),
        ("ten minutes", ["1", "0", "0", "0"]),
    ])
    func cookTimes(said: String, digits: [String]) async throws {
        let plan = try #require(planOf(await offline.route(said, in: microwave)))
        #expect(plan.steps.compactMap(\.label) == ["Time Cook"] + digits + ["Start/Pause"])
        #expect(plan.say == "Press Time Cook, then \(digits.joined(separator: ", ")), then Start.")
    }

    @Test("no Time Cook key means no digits")
    func noTimeCook() async throws {
        let plan = try #require(planOf(await offline.route("2 minutes", in: microwave(without: "Time Cook"))))
        #expect(plan.steps.isEmpty)
        #expect(plan.say.contains("Time Cook"))
    }

    @Test("a missing digit gives no steps")
    func missingDigit() async throws {
        let plan = try #require(planOf(await offline.route("a minute and a half", in: microwave(without: "3"))))
        #expect(plan.steps.isEmpty)
        #expect(plan.say.contains("number keys"))
    }
    
    @Test("a digit on the panel twice gives no steps")
    func duplicateDigit() async throws {
        var twice = microwave
        twice.buttons.append(SurfaceMap.Button(label: "3", bounds: PanelRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05), confidence: 1))
        let plan = try #require(planOf(await offline.route("a minute and a half", in: twice)))
        #expect(plan.steps.isEmpty)
        #expect(plan.say.contains("number keys"))
    }

    @Test("a missing Start key says Start, not number keys")
    func missingStart() async throws {
        let plan = try #require(planOf(await offline.route("2 minutes", in: microwave(without: "Start/Pause"))))
        #expect(plan.steps.isEmpty)
        #expect(plan.say.contains("Start"))
        #expect(!plan.say.contains("number keys"))
    }

    @Test("over 60 minutes gives no steps", arguments: ["cook for 90 minutes", "an hour and a half"])
    func tooLong(said: String) async throws {
        let plan = try #require(planOf(await offline.route(said, in: microwave)))
        #expect(plan.steps.isEmpty)
        #expect(plan.say.contains("too long"))
    }

    @Test("requests about another key, or about not cooking, go to the planner", arguments: [
        "set a timer for 5 minutes", "set the clock to 1:30", "defrost for 5 minutes", "popcorn for 2 minutes",
        "power level 5 for 2 minutes", "delay start by 10 minutes",
        "don't cook for 2 minutes", "stop after 30 seconds", "wait a minute", "1:30 pm",
        "cook for 5",
    ])
    func plannerWords(said: String) async throws {
        // Same answer as the planner alone, so it wasn't turned into a cook plan.
        let routed = try #require(planOf(await offline.route(said, in: microwave)))
        #expect(routed == (await TaskPlanner(service: nil).plan(said, in: microwave)))
    }

    @Test("add 30 seconds still means the Add 30 Sec key")
    func addThirty() async throws {
        let plan = try #require(planOf(await offline.route("add 30 seconds", in: microwave)))
        #expect(plan.steps.compactMap(\.label) == ["Add 30 Sec"])
    }

    // MARK: Planner path

    @Test("press start please still gives Start/Pause")
    func pressStartPlease() async throws {
        let plan = try #require(planOf(await offline.route("press start please", in: microwave)))
        #expect(plan.steps.compactMap(\.label) == ["Start/Pause"])
    }

    @Test("anything else goes to the planner and its server")
    func serverPath() async throws {
        let router = RequestRouter(service: FakePlanService())
        let plan = try #require(planOf(await router.route("start", in: microwave)))
        #expect(plan.steps.compactMap(\.label) == ["Start/Pause"])
        #expect(plan.say == "Press Start.")   // the server's sentence, not the fallback's
    }
}
