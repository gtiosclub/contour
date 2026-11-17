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
        ("heat it for 30 seconds", 30),
        ("cook for 2 minutes", 120),
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
    
    // MARK: Times that came out wrong

    @Test("times that used to come out wrong", arguments: [
        ("2 min 30", 150), ("two minutes thirty", 150), ("a minute thirty", 90), ("1 minute and 30", 90),
        ("a 2 minute cook", 120), ("1 1/2 minutes", 90), ("one and one half minutes", 90),
        ("seventy five seconds", 75), ("eighty seconds", 80), ("minute and a half", 90),
        ("One.5 minutes.", 90), ("1½ minutes", 90),
    ])
    func fixedTimes(said: String, total: Int) throws {
        let time = try #require(CookTime(said))
        #expect(time.minutes * 60 + time.seconds == total)
    }

    @Test("times we can't trust are nil", arguments: [
        // Ranges and numbers that don't add up.
        "5 10 minutes", "2-3 minutes", "2 or 3 minutes", "one hundred twenty seconds", "a hundred and twenty seconds",
        // One time per sentence.
        "cook for 2 minutes, no, 3 minutes", "30 seconds, actually 45 seconds",
        "2 minutes, no, 30 seconds", "cook for 2 minutes then let it sit for 30 seconds", "1:30, actually 2:00",
        // A trailing number that isn't seconds.
        "cook for 1 minute, 3 times", "cook 5 minutes, 2 potatoes",
        // A unit word that isn't a time.
        "2 minutes for the second bowl", "what hour is it", "a second", "one sec",
        // Fractions we don't read.
        "quarter of a minute", "quarter of an hour", "a minute and a quarter",
        "half of a minute", "a third of an hour", ".5 minutes",
        // Clock times.
        "0:00", "cook for 2 minutes at 6:00", "1:30pm", "at 1:30",
        // Not a cook request.
        "give me a minute", "start in 5 minutes", "let it stand for 1 minute", "30 seconds less",
        "set an alarm for 5 minutes",
        // Other words now go to the planner.
        "heat a pizza for 2 minutes", "do a 30 second cook", "2 minutes for half a cup of water",
        "cook my pizza half a minute",
        // Too big to convert.
        "99999999999999999999 seconds", "999999999999999999:00",
    ])
    func untrustedTimes(said: String) {
        #expect(CookTime(said) == nil)
    }
}
