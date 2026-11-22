//
//  CookTimePlanTests.swift
//  ContourTests
//
//  Throwaway multi-step demo: cook times said out loud, and the keys they turn
//  into on labels the way our microwaves read.
//

import ContourCore
import Testing
@testable import ContourApp

private func map(_ labels: [String?]) -> SurfaceMap {
    SurfaceMap(buttons: labels.enumerated().map { i, label in
        SurfaceMap.Button(label: label, bounds: PanelRect(x: Double(i) * 0.03, y: 0, width: 0.02, height: 0.1),
                          confidence: 1)
    }, confidence: 1)
}

/// The labels of "hand-labelled microwave-01.jpg".
private let microwave01 = map([
    "Time Cook", "Defrost Weight/Time", "Add 30 Sec", "Power", "Clock", "Kitchen Timer", "Popcorn", "Potato",
    "Pizza", "Frozen Vegetable", "Beverage", "Dinner Plate", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "Cancel/Off", "0", "Start/Pause",
])

/// The same panel with no Time Cook key, and a key that has a 1 in it.
private let noTimeCook = map([
    "Add 1 Min", "Add 30 Sec", "Popcorn", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Cancel/Off", "0", "Start/Pause",
])

/// That panel with its Time Cook key.
private let addOneMin = map([
    "Time Cook", "Add 1 Min", "Add 30 Sec", "Popcorn", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Cancel/Off", "0",
    "Start/Pause",
])

private func plan(_ request: String, on panel: SurfaceMap = microwave01) throws -> CookTimePlan {
    guard case .plan(let plan) = try #require(CookTimePlan.make(for: request, in: panel)) else {
        Issue.record("no plan for \(request)")
        throw CancellationError()
    }
    return plan
}

private func missing(_ request: String, on panel: SurfaceMap) throws -> String {
    guard case .missing(let sentence) = try #require(CookTimePlan.make(for: request, in: panel)) else {
        Issue.record("a plan for \(request)")
        throw CancellationError()
    }
    return sentence
}

@Suite("Cook times said out loud")
struct CookTimeTests {
    // The first group is what the phone's on-device transcriber wrote when fed
    // these sentences in a synthetic voice on a Mac. Not recorded on a phone.
    @Test("a minute and a half types 1, 3, 0", arguments: [
        "Cook for a minute and a half.", "A minute and a half.", "90 seconds.", "Cook for 90 seconds.",
        "One and a half minutes.", "One minute, 30 seconds.", "One minute 30 seconds.", "130.", "1.5 minutes.",
        "One.5 minutes.",
        "Can you cook this for 90 seconds, please?",
        "cook for a minute and a half", "one minute and a half", "minute and a half", "ninety seconds", "90 sec",
        "90 secs", "90 second", "cook for ninety seconds", "1 and a half minutes", "one and one half minutes",
        "1 1/2 minutes", "1½ minutes", "one point five minutes", "1 minute 30 seconds", "one minute thirty seconds",
        "a minute and thirty seconds", "a minute thirty", "1 minute and 30", "1:30", "cook for 1:30", "one thirty",
        "one-thirty", "microwave my soup for a minute and a half",
    ])
    func minuteAndAHalf(request: String) {
        #expect(CookTime.parse(request)?.digits == "130")
    }

    @Test("two minutes types 2, 0, 0", arguments: [
        "Two minutes.", "2 minutes", "2 minute", "2 min", "2 mins", "two minute", "two-minute", "cook for two minutes",
        "Heat it for 2 minutes, please.", "2:00",
    ])
    func twoMinutes(request: String) {
        #expect(CookTime.parse(request)?.digits == "200")
    }

    @Test("thirty seconds types 3, 0", arguments: [
        "30 seconds.", "Cook for 30 seconds.", "Half a minute.", "thirty seconds", "thirty second", "30 sec", "30 secs",
        "thirty-second", "half minute", "a half minute", "0:30", "start for 30 seconds",
    ])
    func thirtySeconds(request: String) {
        #expect(CookTime.parse(request)?.digits == "30")
    }

    @Test("no cook time we know, so no plan", arguments: [
        "", "start", "Start.", "press start please", "popcorn", "five", "cook", "time cook", "cook for", "next",
        // Cut off, or a time that isn't on the list. Never the nearest one.
        "Cook for a minute.", "a minute", "one minute", " and a half", "3 minutes", "10 minutes", "12 minutes",
        "22 minutes", "twenty two minutes", "30 minutes", "90 minutes", "130 seconds", "230 seconds", "2 seconds",
        "2 minutes and 30 seconds", "two and a half minutes", "2 or 3 minutes", "1 or 2 minutes", "an hour and a half",
        "half an hour", "thirty seconds and two minutes", "2 minutes and a half",
    ])
    func noCookTime(request: String) {
        #expect(CookTime.parse(request) == nil)
    }

    @Test("a sentence that means another key isn't a cook time", arguments: [
        "add 30 seconds", "Add 30 sec", "plus thirty seconds", "+ 30 seconds", "30 more seconds", "another 30 seconds",
        "extra 30 seconds", "set a timer for 2 minutes", "kitchen timer 30 seconds", "defrost for 2 minutes",
        "popcorn for 2 minutes", "power level 2 for 2 minutes", "set the clock to 1:30", "delay start 2 minutes",
        "1:30 pm",
        "stop after 30 seconds", "cancel 30 seconds", "pause for 30 seconds", "don't cook for 2 minutes",
        "don’t cook for 2 minutes", "do not cook for 2 minutes", "minus 30 seconds", "take off 30 seconds", "wait 2 minutes",
    ])
    func otherKeys(request: String) {
        #expect(CookTime.parse(request) == nil)
    }
}

@Suite("The keys for a cook time")
struct CookTimePlanTests {
    @Test("hand-labelled microwave-01.jpg: Time Cook first, then the digits, then Start", arguments: [
        ("cook for a minute and a half", ["Time Cook", "1", "3", "0", "Start"]),
        ("90 seconds", ["Time Cook", "1", "3", "0", "Start"]),
        ("2 minutes", ["Time Cook", "2", "0", "0", "Start"]),
        ("30 seconds", ["Time Cook", "3", "0", "Start"]),
    ])
    func onMicrowave01(request: String, names: [String]) throws {
        let plan = try plan(request)
        #expect(plan.steps.map(\.name) == names)
        #expect(plan.steps.first?.button.label == "Time Cook")
        #expect(plan.steps.last?.button.label == "Start/Pause")
        for step in plan.steps.dropFirst().dropLast() { #expect(step.button.label == step.name) }
    }

    @Test("a panel without Time Cook gets no plan: with Express Cook, a number pressed first can start cooking",
          arguments: ["cook for a minute and a half", "2 minutes", "30 seconds"])
    func withoutTimeCook(request: String) throws {
        #expect(try missing(request, on: noTimeCook) == CookTimePlan.noClearKey(for: ["Time Cook"]))
    }

    @Test("\"1\" means the key that says 1, never Add 1 Min")
    func digitIsExact() throws {
        #expect(try plan("90 seconds", on: addOneMin).steps[1].button.label == "1")
        #expect(try missing("90 seconds", on: map(["Time Cook", "Add 1 Min", "3", "0", "Start"])) == CookTimePlan.noClearKey(for: ["1"]))
    }

    @Test("a repeated digit is two steps on the same button")
    func repeatedDigit() throws {
        let steps = try plan("2 minutes").steps
        #expect(steps[2].name == "0" && steps[3].name == "0")
        #expect(steps[2].button.id == steps[3].button.id)
    }

    @Test("a missing digit: nothing to guide to, and it says which")
    func missingDigit() throws {
        let sentence = try missing("cook for a minute and a half", on: map(["Time Cook", "1", "0", "Start"]))
        #expect(sentence.contains("3"))
        #expect(!sentence.contains("1"))
    }

    @Test("a missing digit is named once, even when it's needed twice")
    func missingDigitOnce() throws {
        let sentence = try missing("2 minutes", on: map(["Time Cook", "2", "Start"]))
        #expect(sentence.contains("for 0 on this panel"))
    }

    @Test("a missing Start: nothing to guide to, and it says which")
    func missingStart() throws {
        let sentence = try missing("30 seconds", on: map(["Time Cook", "3", "0", "Delay Start"]))
        #expect(sentence == CookTimePlan.noClearKey(for: ["Start"]))
        #expect(try missing("30 seconds", on: map(["Time Cook", "3", "Start"])) == CookTimePlan.noClearKey(for: ["0"]))
        #expect(try missing("30 seconds", on: map(["3"])) == CookTimePlan.noClearKey(for: ["Time Cook", "0", "Start"]))
    }

    @Test("two keys that both read as a digit, or as Start, would be a guess")
    func duplicates() throws {
        #expect(try missing("30 seconds", on: map(["Time Cook", "3", "3", "0", "Start"])).contains("for 3 on"))
        #expect(try missing("30 seconds", on: map(["Time Cook", "3", "0", "Start", "START"])).contains("for Start on"))
    }

    @Test("only words exactly time and cook count as Time Cook", arguments: [
        "Time Defrost Express Cook 2", "Time Defrost", "Express Cook", "Express Cook 2", "Time", "Cook", "Time Cook 2",
        "Time tefrosF",
    ])
    func notTimeCook(label: String) throws {
        #expect(try missing("30 seconds", on: map([label, "3", "0", "Start"])) == CookTimePlan.noClearKey(for: ["Time Cook"]))
    }

    @Test("Time Cook in either order and any case", arguments: ["Time Cook", "Cook Time", "TIME COOK", "cook/time"])
    func timeCook(label: String) throws {
        let plan = try plan("30 seconds", on: map([label, "3", "0", "Start"]))
        #expect(plan.steps.first?.button.label == label)
        #expect(plan.steps.first?.name == "Time Cook")
    }

    @Test("two Time Cook keys would be a guess, so it's treated as missing, and says so")
    func twoTimeCooks() throws {
        #expect(try missing("30 seconds", on: map(["Time Cook", "Cook Time", "3", "0", "Start"]))
                == CookTimePlan.noClearKey(for: ["Time Cook"]))
    }

    @Test("Start is called Start out loud, whatever a real scan read it as",
          arguments: ["Start", "START", "START sosec.", "Start Pause", "Start/Pause", "Start/+30 Sec"])
    func startName(label: String) throws {
        let step = try #require(try plan("30 seconds", on: map(["Time Cook", "3", "0", label])).steps.last)
        #expect(step.name == "Start")
        #expect(step.button.label == label)
    }

    @Test("progress names the step and the key")
    func progress() throws {
        let plan = try plan("cook for a minute and a half")
        #expect(plan.progress(at: 0) == "Step 1 of 5: Time Cook")
        #expect(plan.progress(at: 1) == "Step 2 of 5: 1")
        #expect(plan.progress(at: 4) == "Step 5 of 5: Start")
    }

    @Test("what it says up front is the time and the keys, so a misheard time can be stopped")
    func saysTheTime() throws {
        #expect(try plan("90 seconds").say == "Cook for a minute and a half: Time Cook, 1, 3, 0, Start.")
    }

    @Test("the keys every cook time needs, in the order they're pressed")
    func cookTimeKeys() {
        #expect(CookTimePlan.cookTimeKeys == ["Time Cook", "1", "3", "0", "2", "Start"])
        #expect(CookTimePlan.missingKeys(in: microwave01).isEmpty)
        #expect(CookTimePlan.missingKeys(in: noTimeCook) == ["Time Cook"])
        #expect(CookTimePlan.missingKeys(in: map(["Time Cook", "1", "3", "0", "Delay Start"])) == ["2", "Start"])
        #expect(CookTimePlan.missingKeys(in: .empty) == CookTimePlan.cookTimeKeys)
        #expect(CookTimePlan.canGuideACookTime(on: microwave01))
        #expect(CookTimePlan.canGuideACookTime(on: map(["Time Cook", "1", "3", "0", "Start"])), "1:30 and 0:30 need no 2")
        #expect(!CookTimePlan.canGuideACookTime(on: map(["Time Cook", "1", "3", "0", "Delay Start"])), "No Start")
        #expect(!CookTimePlan.canGuideACookTime(on: noTimeCook))
        #expect(!CookTimePlan.canGuideACookTime(on: .empty))
    }

    @Test("no missing keys means every cook time makes a plan, and a missing key means one doesn't", arguments: [
        microwave01, noTimeCook, addOneMin, map(["Time Cook", "1", "3", "0", "Start"]),
        map(["Time Cook", "1", "2", "3", "0", "Start"]), map(["Time Cook", "1", "2", "3", "0", "0", "Start"]),
        map(["Time Cook", "Cook Time", "1", "2", "3", "0", "Start"]), map(["1", "2", "3", "0", "Start"]), .empty,
    ])
    func missingKeysAgreeWithPlans(panel: SurfaceMap) {
        let plans = CookTime.known.map { CookTimePlan.make(for: $0.spoken, in: panel) }
        let allPlan = plans.allSatisfy { if case .plan = $0 { true } else { false } }
        #expect(CookTimePlan.missingKeys(in: panel).isEmpty == allPlan)
    }

    @Test("a request with no cook time falls through to the one-button lookup", arguments: [
        ("start", "Start/Pause"), ("press start please", "Start/Pause"), ("popcorn", "Popcorn"),
        ("add 30 seconds", "Add 30 Sec"), ("plus thirty seconds", "Add 30 Sec"), ("five", "5"),
    ])
    func fallsThrough(request: String, label: String) {
        #expect(CookTimePlan.make(for: request, in: microwave01) == nil)
        #expect(ButtonLookup.button(for: request, in: microwave01)?.label == label)
    }
}

@Suite("Whole sentences in the one-button lookup")
struct WholeSentenceLookupTests {
    // Known cost of hearing the whole sentence. Today's early stop matched these on
    // the word "start". Now they get "No button matching", and the user says it again.
    @Test("extra words the lookup doesn't know are no longer ignored",
          arguments: ["start now", "start the microwave"])
    func extraWords(request: String) {
        #expect(CookTimePlan.make(for: request, in: microwave01) == nil)
        #expect(ButtonLookup.button(for: request, in: microwave01) == nil)
    }

    @Test("what the transcriber writes for a single word still finds the key",
          arguments: [("Start.", "Start/Pause"), ("Press start, please.", "Start/Pause"), ("Add 30 seconds.", "Add 30 Sec")])
    func transcribed(request: String, label: String) {
        #expect(CookTimePlan.make(for: request, in: microwave01) == nil)
        #expect(ButtonLookup.button(for: request, in: microwave01)?.label == label)
    }
}

@Suite("Hearing next")
struct NextWordTests {
    @Test("the word next, however it's written", arguments: ["next", "Next.", "NEXT", "okay next please", "next, please"])
    func heard(text: String) {
        #expect(NextWord.isIn(text))
    }

    @Test("not next", arguments: ["", "text", "nexus", "nextdoor", "start", "Target reached", "Stop. Hold here."])
    func notHeard(text: String) {
        #expect(!NextWord.isIn(text))
    }
}
