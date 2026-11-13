//
//  CookTime.swift
//  SurfaceUnderstanding
//
//  Created by Asav Gupta on 11/5/26.
//

import Foundation

/// A cook time in minutes and seconds.
public struct CookTime: Hashable, Sendable {
    public var minutes: Int
    public var seconds: Int

    /// Seconds over 59 roll into minutes.
    public init(totalSeconds: Int) {
        minutes = totalSeconds / 60
        seconds = totalSeconds % 60
    }

    /// The time in `request`, or nil if there's none or it can't be trusted.
    /// A number needs a unit, so "cook for 5" isn't a time.
    public init?(_ request: String) {
        let text = request.lowercased()
        // "1:30". "0:00" isn't a time.
        if let match = text.firstMatch(of: /(\d+):(\d\d)/) {
            guard let m = Int(match.1), let s = Int(match.2), m * 60 + s > 0 else { return nil }
            self.init(totalSeconds: m * 60 + s)
            return
        }
        let words = text.replacingOccurrences(of: "½", with: " ½ ")
            .split { !$0.isLetter && !$0.isNumber && !"./'".contains($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        // Quarters aren't handled: nil beats a wrong time.
        if words.contains(where: { $0.hasPrefix("quarter") }) { return nil }

        var total = 0.0
        var number: Double?               // a number waiting for its unit
        var numberIsTens = false          // "forty" can still take "five"
        var numberAfterMinutes = false    // the number came right after minutes
        var half = false                  // "half" waiting for its unit
        var lastUnit: Double?             // the unit just read, so "and a half" can follow
        var smallest = Double.infinity    // each unit must be smaller than the last
        var afterMinutes = false

        // A number that never got a unit is seconds right after minutes
        // ("2 min 30"). Anywhere else it means we can't trust the time.
        func settle() -> Bool {
            guard let n = number else { return true }
            guard numberAfterMinutes, smallest == 60, n < 60, n == n.rounded() else { return false }
            total += n
            smallest = 1
            number = nil
            return true
        }

        var i = 0
        while i < words.count {
            let word = words[i]
            let next = i + 1 < words.count ? words[i + 1] : ""
            if Self.halves.contains(word) || (["a", "an", "one"].contains(word) && Self.halves.contains(next)) {
                if !Self.halves.contains(word) { i += 1 }                         // "a half", "one half"
                if let n = number { number = n + 0.5; numberIsTens = false }      // two and a half
                else if let unit = lastUnit { total += unit / 2; lastUnit = nil } // a minute and a half
                else { half = true }                                              // half a minute
                afterMinutes = false
            } else if word == "a" || word == "an", Self.units[next] != nil, number == nil, !half {
                number = 1                                                        // a minute
                numberIsTens = false
                numberAfterMinutes = false
            } else if let n = Self.value(word) {
                if let p = number {
                    // Only "forty five" adds up; "5 10" and "one hundred" can't be trusted.
                    guard numberIsTens, Self.numbers[word] != nil, (1.0...9.0).contains(n) else { return nil }
                    number = p + n
                    numberIsTens = false
                } else {
                    number = n
                    numberIsTens = Self.tens.contains(word)
                    numberAfterMinutes = afterMinutes
                }
                lastUnit = nil
            } else if let unit = Self.units[word] {
                var count = number
                if count == nil, half { count = 0.5 }
                if count == nil, Self.singular.contains(word) { count = 1 }
                if let count {
                    guard unit < smallest else { return nil }   // "2 minutes, no, 3 minutes"
                    total += count * unit
                    smallest = unit
                    lastUnit = unit
                }
                afterMinutes = unit == 60 && count != nil
                number = nil
                half = false
            } else if !["and", "a", "an"].contains(word) {
                // Any other word ends the time: "and a half" can't follow it now.
                guard settle() else { return nil }
                number = nil
                half = false
                lastUnit = nil
                afterMinutes = false
            }
            i += 1
        }
        guard settle() else { return nil }
        // "a second" or "one sec" means wait, not cook.
        let seconds = Int(total.rounded())
        guard seconds > 1 else { return nil }
        self.init(totalSeconds: seconds)
    }

    /// The keys to type: 1:30 is 1, 3, 0 and 0:45 is 4, 5.
    public var digits: [String] {
        let text = minutes > 0 ? "\(minutes)" + String(format: "%02d", seconds) : "\(seconds)"
        return text.map(String.init)
    }

    private static let numbers: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Tens that can take a ones word after them, as in "forty five".
    private static let tens: Set = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// A unit with no number before it counts as one, as in "minute and a half".
    private static let singular: Set = ["second", "sec", "minute", "min", "hour"]

    private static let halves: Set = ["half", "1/2", "½"]

    /// "1.5", "forty" or "one.5" as a number.
    private static func value(_ word: String) -> Double? {
        if word.first?.isNumber == true { return Double(word) }
        if let n = numbers[word] { return n }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, let whole = numbers[String(parts[0])],
           !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) {
            return Double("\(Int(whole)).\(parts[1])")
        }
        return nil
    }

    private static let units: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3600, "hours": 3600,
    ]
}
