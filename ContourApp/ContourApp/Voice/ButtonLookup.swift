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
        let named = request.split(whereSeparator: \.isWhitespace).filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        return TargetMatcher().match(named.joined(separator: " "), in: map)?.button
    }

    /// Whether `request` has stop, halt, pause or cancel in it. TargetMatcher has
    /// rules for those keys, like pause never becoming Cancel, that a plan from
    /// anywhere else could break, so the phone answers these even when it has no key.
    static func mentionsStopping(_ request: String) -> Bool {
        request.lowercased().split { !$0.isLetter }.contains { stopWords.contains(String($0)) }
    }

    private static let stopWords: Set<String> = ["stop", "halt", "pause", "cancel"]

    /// Words people say around a button's name that aren't part of it.
    private static let fillers: Set<String> = [
        "the", "a", "an", "please", "press", "push", "hit", "tap", "button", "to", "i", "want",
        "need", "can", "you", "find", "where", "is", "it", "me", "take", "guide",
    ]
}
