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
    /// TargetMatcher first, on the whole request. Then word by word, still
    /// through TargetMatcher so its synonyms apply ("go" is Start), against
    /// each word of each label: that finds Start on a key read as "Start Pause"
    /// off two lines, which the matcher can't split yet. When several labels
    /// name it, the shortest wins, so "Start" beats "Start Time".
    static func button(for request: String, in map: SurfaceMap) -> SurfaceMap.Button? {
        let matcher = TargetMatcher()
        if let match = matcher.match(request, in: map) { return match.button }

        let spoken = words(request).filter { !fillers.contains($0) }
        guard !spoken.isEmpty else { return nil }

        let named = map.buttons.compactMap { button -> (button: SurfaceMap.Button, size: Int)? in
            guard let label = button.label else { return nil }
            let labelWords = words(label)
            let says = labelWords.contains { labelWord in
                let single = SurfaceMap(
                    buttons: [SurfaceMap.Button(label: labelWord, bounds: button.bounds, confidence: button.confidence)],
                    confidence: 1
                )
                return spoken.contains { matcher.match($0, in: single) != nil }
            }
            return says ? (button, labelWords.count) : nil
        }
        return named.min { $0.size < $1.size }?.button
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Words people say around a button's name that aren't part of it.
    private static let fillers: Set<String> = [
        "the", "a", "an", "please", "press", "push", "hit", "tap", "button", "to", "i", "want",
        "need", "can", "you", "find", "where", "is", "it", "me", "take", "guide",
    ]
}
