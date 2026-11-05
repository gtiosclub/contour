//
//  ButtonLookup.swift
//  ContourApp — Officers (integration)
//
//  Which button a request names: "start", "press start please", "go", "five".
//

import ContourCore
import Foundation
import SurfaceUnderstanding

nonisolated enum ButtonLookup {

    /// The button `request` names on `map`, or `nil`.
    ///
    /// Drops the words people say around a button's name, then asks
    /// TargetMatcher once. Everything else is the matcher's: synonyms ("go" is
    /// Start), whole-word matches ("start" finds a key read as "Start Pause"),
    /// and the guards that keep a display or merged text from being a key.
    static func button(for request: String, in map: SurfaceMap) -> SurfaceMap.Button? {
        match(for: request, in: map)?.button
    }

    /// Whether `request` names a key well enough that nobody else needs asking.
    /// Below 0.8 the key isn't there, and the matcher is offering the next safest one.
    static func isConfident(_ request: String, in map: SurfaceMap) -> Bool {
        (match(for: request, in: map)?.confidence ?? 0) >= 0.8
    }

    private static func match(for request: String, in map: SurfaceMap) -> TargetMatch? {
        let named = request.split(whereSeparator: \.isWhitespace).filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        return TargetMatcher().match(named.joined(separator: " "), in: map)
    }

    /// Words people say around a button's name that aren't part of it.
    private static let fillers: Set<String> = [
        "the", "a", "an", "please", "press", "push", "hit", "tap", "button", "to", "i", "want",
        "need", "can", "you", "find", "where", "is", "it", "me", "take", "guide",
    ]
}
