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

    /// The time in `request`, or nil if there's none. A number needs a unit,
    /// so "cook for 5" isn't a time.
    public init?(_ request: String) {
        let text = request.lowercased()
        // "1:30"
        if let match = text.firstMatch(of: /(\d+):(\d\d)/), let m = Int(match.1), let s = Int(match.2) {
            self.init(totalSeconds: m * 60 + s)
            return
        }
        // "and a half" and "a half minute" both read as "half".
        let words = text.replacingOccurrences(of: "a half", with: "half")
            .split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }

        var total = 0.0
        var pending: Double?    // a number still waiting for its unit
        var lastUnit: Double?   // seconds in the last unit read
        for word in words {
            if let n = (word.first?.isNumber == true ? Double(word) : nil) ?? Self.numbers[word] {
                pending = (pending ?? 0) + n                       // "forty five"
            } else if word == "half" {
                if let p = pending { pending = p + 0.5 }            // two and a half minutes
                else if let unit = lastUnit { total += unit / 2 }   // a minute and a half
                else { pending = 0.5 }                              // half a minute
            } else if word == "a" || word == "an" {
                if pending == nil { pending = 1 }                   // a minute
            } else if let unit = Self.units[word] {
                if let p = pending { total += p * unit; lastUnit = unit }
                pending = nil
            } else if word != "and" {
                pending = nil                                       // "a pizza for 2 minutes"
            }
        }
        guard total > 0 else { return nil }
        self.init(totalSeconds: Int(total.rounded()))
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
        "sixty": 60, "ninety": 90,
    ]

    private static let units: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3600, "hours": 3600,
    ]
}
