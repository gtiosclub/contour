//
//  CookTimePlan.swift
//  ContourApp — throwaway multi-step demo, not for merging
//
//  "cook for a minute and a half" to Time Cook, 1, 3, 0, Start, on the phone with
//  no server. The real versions are #165 (cook times) and #161 (walking the steps).
//

import ContourCore
import Foundation
import SurfaceUnderstanding

/// A cook time said out loud, as the digits to type.
nonisolated struct CookTime: Equatable {
    var digits: String
    var spoken: String

    /// The cook time in `request`, or `nil` if there isn't exactly one we know.
    ///
    /// Works on whole words, so "12 minutes" is not "2 minutes". A second number
    /// or unit anywhere in the sentence ("2 minutes and 30 seconds", "2 and a
    /// half minutes") means we didn't understand it, so it's `nil`, not a guess.
    static func parse(_ request: String) -> CookTime? {
        let said = words(in: request)
        guard !said.contains(where: otherKeys.contains) else { return nil }
        let sentence = " \(said.joined(separator: " ")) "
        for (phrase, time) in phrases {
            guard let range = sentence.range(of: " \(phrase) ") else { continue }
            let rest = "\(sentence[..<range.lowerBound]) \(sentence[range.upperBound...])"
            let saysMore = rest.split(separator: " ").contains { word in
                word.contains(where: \.isNumber) || units.contains(String(word))
            }
            return saysMore ? nil : time
        }
        return nil
    }

    /// Whether `request` has any amount of time or number in it, known or not. The
    /// plan server got 1:30 wrong again on Monday with no warning, so these stay on
    /// the phone. "One" spelled out counts too: the server planned "cook for one" as
    /// 1, 0, 0, so "the popcorn one" stays on the phone as well.
    static func mentionsATime(_ request: String) -> Bool {
        request.contains(where: \.isNumber) || words(in: request).contains { word in
            units.contains(word) || word.contains(where: \.isNumber)
        }
    }

    /// Every cook time the phone plans by itself.
    static var known: [CookTime] { times.map(\.time) }

    private static let times: [(time: CookTime, phrases: [String])] = [
        (CookTime(digits: "130", spoken: "a minute and a half"), [
            "a minutes and a half", "1 minutes and a half", "minutes and a half",
            "1 and a half minutes", "1 and 1 half minutes", "1 and 1/2 minutes", "1 1/2 minutes",
            "1.5 minutes", "1 point 5 minutes", "one.5 minutes",
            "a minutes 30 seconds", "a minutes and 30 seconds", "a minutes 30", "a minutes and 30",
            "1 minutes 30 seconds", "1 minutes and 30 seconds", "1 minutes 30", "1 minutes and 30",
            "90 seconds", "1:30", "130", "1 30",
        ]),
        (CookTime(digits: "200", spoken: "2 minutes"), ["2 minutes", "2:00"]),
        (CookTime(digits: "30", spoken: "30 seconds"), [
            "30 seconds", "half a minutes", "a half minutes", "half minutes", "0:30",
        ]),
    ]

    /// Longest first, so "a minute 30 seconds" is never just "30 seconds".
    private static let phrases: [(phrase: String, time: CookTime)] = times
        .flatMap { entry in entry.phrases.map { (phrase: $0, time: entry.time) } }
        .sorted { $0.phrase.count > $1.phrase.count }

    /// These mean a different key: "add 30 seconds" is Add 30 Sec, and "set a
    /// timer for 2 minutes" or "don't cook for 2 minutes" shouldn't cook anything.
    private static let otherKeys: Set<String> = [
        "add", "plus", "+", "more", "extra", "another",
        "timer", "clock", "defrost", "popcorn", "power", "delay", "am", "pm",
        "stop", "cancel", "pause", "don't", "don’t", "not", "minus", "off", "wait",
    ]

    private static let units: Set<String> = ["seconds", "minutes", "hour", "hours", "half", "quarter"]

    private static let spellings: [String: String] = [
        "sec": "seconds", "secs": "seconds", "second": "seconds",
        "min": "minutes", "mins": "minutes", "minute": "minutes",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90", "hundred": "100",
    ]

    /// Lowercase words with their edge punctuation gone, spelled one way. The
    /// recognizer writes "One minute, 30 seconds." and "130."
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "½", with: " 1/2")
            .split { $0.isWhitespace || $0 == "-" || $0 == "," }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
            .map { spellings[$0] ?? $0 }
    }
}

/// The keys to press for a cook time, in order.
nonisolated struct CookTimePlan: Equatable {
    struct Step: Equatable {
        /// What to call the key out loud. Not its label, which may be "Start/Pause"
        /// or "START sosec." off a real scan.
        var name: String
        var button: SurfaceMap.Button
    }

    /// What can come of a request with a cook time in it.
    enum Outcome: Equatable {
        case plan(CookTimePlan)
        /// Nothing to guide to: a key we need isn't on the map, or the keys
        /// aren't safe to press in that order. Says which.
        case missing(String)
    }

    var steps: [Step]
    var say: String

    func progress(at index: Int) -> String {
        "Step \(index + 1) of \(steps.count): \(steps[index].name)"
    }

    /// The plan for `request` on `map`. `nil` if it has no cook time, so it can
    /// go on to the one-button lookup.
    ///
    /// Time Cook is always first. On a panel with Express Cook, like the demo
    /// Magic Chef, a number pressed first can start cooking, so without a Time
    /// Cook key there's no plan.
    static func make(for request: String, in map: SurfaceMap) -> Outcome? {
        guard let time = CookTime.parse(request) else { return nil }
        let names = ["Time Cook"] + time.digits.map(String.init) + ["Start"]
        let steps = names.compactMap { name in key(named: name, in: map).map { Step(name: name, button: $0) } }
        guard steps.count == names.count else {
            var missing: [String] = []
            for name in names where key(named: name, in: map) == nil && !missing.contains(name) {
                missing.append(name)
            }
            return .missing(noClearKey(for: missing))
        }
        return .plan(CookTimePlan(steps: steps, say: "Cook for \(time.spoken): \(names.joined(separator: ", "))."))
    }

    /// Every key the phone's cook times press, in the order they're pressed.
    static let cookTimeKeys: [String] = {
        var keys = ["Time Cook"]
        for digit in CookTime.known.flatMap(\.digits).map(String.init) where !keys.contains(digit) {
            keys.append(digit)
        }
        return keys + ["Start"]
    }()

    /// The keys in `cookTimeKeys` that `map` has no one clear key for. Empty
    /// means every cook time the phone knows can be guided on it.
    static func missingKeys(in map: SurfaceMap) -> [String] {
        cookTimeKeys.filter { key(named: $0, in: map) == nil }
    }

    /// Whether `map` has one clear key for every step of at least one cook time
    /// the phone knows, so a minute and a half still works when only the 2 for
    /// 2:00 wasn't read.
    static func canGuideACookTime(on map: SurfaceMap) -> Bool {
        let missing = missingKeys(in: map)
        return CookTime.known.contains { time in
            !(["Time Cook", "Start"] + time.digits.map(String.init)).contains(where: missing.contains)
        }
    }

    /// The one key a plan step called `name` goes to: Time Cook, Start, or the
    /// key labelled with exactly that digit.
    static func key(named name: String, in map: SurfaceMap) -> SurfaceMap.Button? {
        switch name {
        case "Time Cook": only(in: map, where: isTimeCook)
        case "Start": TargetMatcher().match("start", in: map)?.button
        default: only(in: map) { $0.trimmingCharacters(in: .whitespacesAndNewlines) == name }
        }
    }

    static func noClearKey(for names: [String]) -> String {
        "I can't find one clear key for \(names.formatted(.list(type: .and))) on this panel, "
            + "so I won't guess. Try scanning again."
    }

    /// The one button whose label passes `test`. Two of them would be a guess.
    static func only(in map: SurfaceMap, where test: (String) -> Bool) -> SurfaceMap.Button? {
        let found = map.buttons.filter { $0.label.map(test) ?? false }
        return found.count == 1 ? found[0] : nil
    }

    /// Its words are exactly time and cook. "Time Defrost Express Cook 2" is
    /// several keys read as one.
    static func isTimeCook(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.count == 2 && Set(words) == ["time", "cook"]
    }
}

/// The word that moves a plan on to its next key.
nonisolated enum NextWord {
    static func isIn(_ text: String) -> Bool {
        text.lowercased().split { !$0.isLetter }.contains("next")
    }
}
