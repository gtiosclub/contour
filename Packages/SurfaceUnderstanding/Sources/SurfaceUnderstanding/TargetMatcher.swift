//
//  TargetMatcher.swift
//  SurfaceUnderstanding — Surface / Target Matching
//
//  The user says what they want; this decides which control they meant.
//
//  "Start" is easy. "the popcorn one", "defrost", "thirty seconds" and
//  "the big button" are the actual traffic, and they arrive as whatever the
//  speech recogniser heard — lowercased, unpunctuated, sometimes wrong.
//
//  ⚠️ notFound AND lowConfidence ARE DIFFERENT ANSWERS.
//  Returning `nil` means "that control is not on this panel" — the user should
//  stop looking for it. Returning a match with low `confidence` means "I think
//  it is this one but I would be guessing" — the user should re-aim and retry.
//  The app target turns those into `OutcomeSignal.notFound` and
//  `.lowConfidence`, which Experience is required to make feel different. If you
//  collapse the two here, no amount of good haptics downstream can recover the
//  distinction.
//
//  A wrong confident match is the worst outcome available to this package: it
//  sends a finger that cannot see to a button nobody asked for. Prefer a low
//  confidence over a confident guess.
//
//  COORDINATES: nothing here is positional — you are matching text against
//  `SurfaceMap.Button.label`. Bounds come along on the button you return, already
//  in normalized panel space. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A control the matcher believes the user asked for, and how sure it is.
public struct TargetMatch: Hashable, Sendable {

    /// The control to guide the finger to.
    public var button: SurfaceMap.Button

    /// How sure the matcher is that this is what the user meant, `0...1`.
    ///
    /// Distinct from `SurfaceMap.Button.confidence`, which is how sure the
    /// *detector* was that a button is there at all. Both can be low, and they
    /// mean different things: a crisply detected button matched to a vague
    /// request, or a well-understood request matched to a scuffed detection.
    public var confidence: Double

    public init(button: SurfaceMap.Button, confidence: Double) {
        self.button = button
        self.confidence = confidence
    }
}

/// Matches a spoken or typed request against the controls on a panel.
public struct TargetMatcher: Sendable {

    public init() {}

    // MARK: - Tables

    /// Table for lists of words that `match` will match to.
    /// Every control has its own key, so pause never turns into cancel and
    /// time, timer and clock never turn into each other.
    private let synonymTable: [String: String] = [
        // ===== Start =====
        "start": "start", "go": "start", "begin": "start", "run": "start", "play": "start",
        // ===== Stop =====
        "stop": "stop", "halt": "stop",
        // ===== Pause =====
        "pause": "pause",
        // ===== Cancel =====
        "cancel": "cancel",
        // ===== Clear =====
        "clear": "clear",
        // ===== Defrost =====
        "defrost": "defrost", "thaw": "defrost", "unfreeze": "defrost",
        // ===== Popcorn =====
        "popcorn": "popcorn", "pop": "popcorn",
        // ===== Time / Timer / Clock (three different keys) =====
        "time": "time",
        "timer": "timer",
        "clock": "clock",
        // ===== Add 30 =====
        "add30": "add30", "+30": "add30", "addthirty": "add30", "+thirty": "add30",
        "add30sec": "add30", "add30seconds": "add30", "addthirtyseconds": "add30",
        // ===== Numbers to Digits =====
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "thirty": "30",
        // ===== Add One Minute =====
        "add one minute": "add one minute", "oneminute": "add one minute", "addoneminute": "add one minute",
        "+ 1 minute": "add one minute", "+1 minute": "add one minute", "plus 1 minute": "add one minute",
        "plus one minute": "add one minute", "add 1 minute": "add one minute",
    ]

    /// Single-word spellings that mean the same thing, used by `words`.
    private let wordTable: [String: String] = [
        "seconds": "sec", "second": "sec", "secs": "sec",
        "plus": "add", "+": "add",
    ]

    /// Words a person may say that are often not printed on the key.
    private let optionalWords: Set<String> = ["kitchen", "level"]

    /// What to try when the panel doesn't have the key that was asked for.
    /// Pause never falls back to Cancel: Cancel can wipe the time they set.
    private let fallbacks: [String: [String]] = [
        "stop": ["cancel", "pause"],
        "pause": ["stop"],
        "cancel": ["stop"],
    ]

    // MARK: - Text helpers

    /// Cleans up the input data so it's lowercased, trimmed of spaces and end space, and only
    /// allows certain characters
    private func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "+"))
        let scalars = lowered.unicodeScalars.lazy.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Helper for `match` that removes spaces in between words
    private func canonical(_ normalized: String) -> String {
        if let hit = synonymTable[normalized] { return hit }
        let squashed = normalized.replacingOccurrences(of: " ", with: "")
        if let hit = synonymTable[squashed] { return hit }
        return squashed
    }
    
    /// Breaks a request or a label into words, built the same way for both,
    /// so "plus thirty seconds" and "+ 30 Sec" both become ["add30"].
    private func words(_ text: String) -> [String] {
        var result: [String] = []
        for chunk in text.split(whereSeparator: { $0 == "/" || $0.isWhitespace }) {
            // "+30" -> "+", "30"
            let pieces = (chunk.count > 1 && chunk.hasPrefix("+"))
                ? ["+", String(chunk.dropFirst())]
                : [String(chunk)]
            for piece in pieces {
                let word = normalize(piece)
                guard !word.isEmpty else { continue }
                result.append(wordTable[word] ?? synonymTable[word] ?? word)
            }
        }
        // 30 next to add or sec is the +30 key, in any order.
        if result.contains("30"), result.contains("add") || result.contains("sec") {
            result.removeAll { $0 == "30" || $0 == "add" || $0 == "sec" }
            result.append("add30")
        }
        return result
    }
    
    // MARK: - Which labels can be a key

    /// The words of a label, or nil if this label can't be the key asked for.
    private func keyWords(_ label: String, for wanted: [String]) -> [String]? {
        // A display like 1:35 is never a key. Checked on the raw label,
        // because normalize drops the ":".
        if label.range(of: #"\d:\d"#, options: .regularExpression) != nil { return nil }
        let have = words(label)
        // Five or more words is merged text, not one key.
        if have.count > 4 { return nil }
        // A number only matches a key that is exactly that number.
        let wantsNumber = wanted.allSatisfy { $0.allSatisfy(\.isNumber) }
        if wantsNumber && have != wanted { return nil }
        // "start" never means Delay Start or Time Start.
        if wanted.contains("start"), have.contains("delay") || have.contains("time") { return nil }
        return have
    }

    /// Keeps the labels with the fewest extra words. More than one left is a tie.
    private func fewestExtra(_ candidates: [(button: SurfaceMap.Button, extra: Int)],
                             confidence: Double) -> [TargetMatch] {
        guard let fewest = candidates.map(\.extra).min() else { return [] }
        return candidates
            .filter { $0.extra == fewest }
            .map { TargetMatch(button: $0.button, confidence: confidence) }
    }
    
    // MARK: - Passes

    /// Pass 1: the whole label equals the request, or a synonym of it.
    /// 1.0 when the text is identical, 0.9 when it took a synonym.
    private func exactMatches(_ request: String, in map: SurfaceMap) -> [TargetMatch] {
        let normalizedRequest = normalize(request)
        guard !normalizedRequest.isEmpty else { return [] }
        let wanted = canonical(normalizedRequest)

        var matches: [TargetMatch] = []
        for button in map.buttons {
            guard let label = button.label else { continue }
            let whole = normalize(label)
            guard !whole.isEmpty, canonical(whole) == wanted else { continue }
            let confidence = (whole == normalizedRequest) ? 1.0 : 0.9
            matches.append(TargetMatch(button: button, confidence: confidence))
        }
        return matches
    }

    /// Pass 2: every word of the request is a whole word of the label. 0.8.
    private func wordMatches(_ request: String, in map: SurfaceMap) -> [TargetMatch] {
        let wanted = words(request).filter { !optionalWords.contains($0) }
        guard !wanted.isEmpty else { return [] }

        var candidates: [(button: SurfaceMap.Button, extra: Int)] = []
        for button in map.buttons {
            guard let label = button.label, let have = keyWords(label, for: wanted) else { continue }
            guard Set(wanted).isSubset(of: Set(have)) else { continue }
            candidates.append((button: button, extra: have.count - wanted.count))
        }
        return fewestExtra(candidates, confidence: 0.8)
    }

    /// The normal lookup: pass 1, and pass 2 only if pass 1 found nothing.
    /// Empty = not on the panel, one = a match, several = a tie.
    private func lookup(_ request: String, in map: SurfaceMap) -> [TargetMatch] {
        let exact = exactMatches(request, in: map)
        return exact.isEmpty ? wordMatches(request, in: map) : exact
    }

    // MARK: - Match

    /// Returns the one control the request means, or nil if it isn't on the
    /// panel or more than one control could be it.
    public func match(_ request: String, in map: SurfaceMap) -> TargetMatch? {
        let asked = words(request)

        // "time" alone means Time Cook. A bare Time label is the display or a
        // misread Timer key, so never fall back to it.
        if asked == ["time"] {
            let found = lookup("time cook", in: map)
            guard found.count == 1 else { return nil }
            return TargetMatch(button: found[0].button, confidence: min(found[0].confidence, 0.9))
        }

        let found = lookup(request, in: map)
        if found.count == 1 { return found[0] }
        if found.count > 1 { return nil }   // a tie: ask, don't guess

        // The key isn't there: try the next safest key, at 0.7.
        if asked.count == 1, let alternatives = fallbacks[asked[0]] {
            for alternative in alternatives {
                let tried = lookup(alternative, in: map)
                if tried.count == 1 { return TargetMatch(button: tried[0].button, confidence: 0.7) }
                if tried.count > 1 { return nil }
            }
        }
        return nil
    }
}
