//
//  CookTimeTests.swift
//  SurfaceUnderstanding
//
//  Created by Asav Gupta on 11/5/26.
//

import Testing
@testable import SurfaceUnderstanding

@Suite("Cook times")
struct CookTimeTests {

    @Test("every row in the issue's table gives those digits", arguments: [
        ("a minute and a half", ["1", "3", "0"]),
        ("90 seconds", ["1", "3", "0"]),
        ("1:30", ["1", "3", "0"]),
        ("2 minutes", ["2", "0", "0"]),
        ("two and a half minutes", ["2", "3", "0"]),
        ("45 sec", ["4", "5"]),
        ("half a minute", ["3", "0"]),
        ("ten minutes", ["1", "0", "0", "0"]),
    ])
    func table(said: String, digits: [String]) throws {
        #expect(try #require(CookTime(said)).digits == digits)
    }

    @Test("variations read the same time", arguments: [
        ("Cook for a minute and a half, please.", 90),
        ("1 minute 30 seconds", 90),
        ("2 mins", 120),
        ("forty five seconds", 45),
        ("a half minute", 30),
        ("heat a pizza for 2 minutes", 120),
    ])
    func variations(said: String, total: Int) throws {
        let time = try #require(CookTime(said))
        #expect(time.minutes * 60 + time.seconds == total)
    }

    @Test("a number with no unit isn't a time", arguments: ["cook for 5", "start", "press 1", ""])
    func noTime(said: String) {
        #expect(CookTime(said) == nil)
    }

    @Test("seconds over 59 roll into minutes")
    func rollover() {
        let time = CookTime(totalSeconds: 90)
        #expect(time.minutes == 1 && time.seconds == 30)
        #expect(CookTime("90 seconds") == time)
    }
}
