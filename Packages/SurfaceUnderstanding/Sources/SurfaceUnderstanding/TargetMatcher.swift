//
//  TargetMatcher.swift
//  SurfaceUnderstanding — Surface / Labels & Target Matching
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

    /// Find the control on `map` that best answers `request`.
    ///
    /// - Parameters:
    ///   - request: what the user asked for, as recognised. May be empty, may be
    ///     misheard, may name something that is not on this panel.
    ///   - map: the panel to search.
    /// - Returns: the best match and how sure it is, or `nil` when nothing on the
    ///   panel plausibly answers the request — which the app target reports as
    ///   `OutcomeSignal.notFound`.
    ///
    /// Pure and synchronous on purpose — this is the part a test can pin, and
    /// matching rules are exactly the kind of thing that regresses silently.
    /// Unlabelled buttons (`label == nil`) can never match by text; if the
    /// request is positional ("top left"), that is a separate problem and it is
    /// not this method's job yet.
    
    ///A manual HashMap/Dictionary of values that would be given for a microwave
    private let synonymTable: [String : String] = [
        //===== Start =====
        "start" : "start", "go" : "start", "begin" : "start", "run" : "start", "play" : "start",
        //===== Stop =====
        "stop" : "stop", "pause" : "stop", "halt" : "stop", "cancel" : "stop", "clear" : "stop",
        //===== Defrost =====
        "defrost" : "defrost", "thaw" : "defrost", "unfreeze" : "defrost",
        //===== Time =====
        "timer" : "timer", "clock" : "timer", "time" : "timer",
        //===== add 30 =====
        "add30" : "add30", "+30" : "add30", "addthirty" : "add30", "+thirty" : "add30",
        //===== Numbers to Digits =====
        "one" : "1", "two" : "2", "three" : "3", "four" : "4", "five" : "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "thirty" : "30",
        //===== add one minute =====
        "add one minute" : "add one minute", "oneminute" : "add one minute", "addoneminute" : "add one minute",
        "+ 1 minute" : "add one minute", "+1 minute" : "add one minute", "plus 1 minute" : "add one minute",
        "plus one minute" : "add one minute", "add 1 minute" : "add one minute",
    ]
    
    ///Makes the given input String:
    /// Lowercased
    /// Only contain letters, numbers and "+"
    /// Filters those out through a given scalar
    /// Then returns the Unicode version of that scalar that is removed of whitespace and only has 1 space between words
    
    private func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "+"))
        let scalars = lowered.unicodeScalars.lazy.filter { allowed.contains($0)}
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
    
    ///Splits a label on "/" into matchable, normazlied parts
    
    private func labelParts(_ label: String) -> [String] {
        label.split(separator: "/")
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
    
    public func match(_ request: String, in map: SurfaceMap) -> TargetMatch? {
        fatalError("unimplemented — owned by Surface / Labels & Target Matching")
    }
}
