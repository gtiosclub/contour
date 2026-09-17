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
    public func match(_ request: String, in map: SurfaceMap) -> TargetMatch? {
        fatalError("unimplemented — owned by Surface / Labels & Target Matching")
    }
}
