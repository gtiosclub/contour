
//
//  ScanProblem.swift
//  SurfaceUnderstanding
//
//  Converts scan failures and missing targets into feedback
//  that Experience can speak.
//

import ContourCore
import Foundation

public enum ScanProblem: Hashable, Sendable {
    case noPanel
    case scanFailed
    case panelCutOff
    case noButtons
    case cantRead(target: String)
    case notOnPanel(target: String)

    public var spoken: String {
        switch self {
        case .noPanel:
            return "I can't see the panel"

        case .scanFailed:
            return "That scan didn't work. Try again"

        case .panelCutOff:
            return "I can see buttons but not the whole panel. Move back a little"

        case .noButtons:
            return "I can't find any buttons. Point the phone at the control panel"

        case .cantRead(let target):
            return "I think I see \(target), but I can't read it. Hold still and scan again"

        case .notOnPanel(let target):
            return "I couldn't find \(target) on this panel"
        }
    }

    public static func after(_ error: any Error) -> ScanProblem? {
        if error is CancellationError {
            return nil
        }

        if let surfaceError = error as? SurfaceUnderstandingError {
            switch surfaceError {
            case .noPanelFound:
                return .noPanel

            case .cancelled:
                return nil

            case .undecodableImage, .underlying:
                return .scanFailed
            }
        }

        return .scanFailed
    }

    public static func after(
        _ detection: PanelDetection,
        photo: PanelPhoto,
        target: String?
    ) -> ScanProblem? {
        if detection.quad == .fullFrame {
            return .panelCutOff
        }

        if detection.map.buttons.isEmpty {
            return .noButtons
        }

        guard let target else {
            return nil
        }

        if TargetMatcher().match(target, in: detection.map) != nil {
            return nil
        }

        if isNearMiss(target: target, in: detection.map) {
            return .cantRead(target: target)
        }

        return .notOnPanel(target: target)
    }

    static func isNearMiss(target: String, in map: SurfaceMap) -> Bool {
        let targetWords = target.split(whereSeparator: { !$0.isLetter })

        guard targetWords.count == 1 else {
            return false
        }

        let wanted = String(targetWords[0]).lowercased()

        guard wanted.count >= 5 else {
            return false
        }

        for button in map.buttons {
            guard let label = button.label else {
                continue
            }

            let words = label.lowercased()
                .split(whereSeparator: { !$0.isLetter })

            for word in words {
                if isOneEditAway(wanted, String(word)) {
                    return true
                }
            }
        }

        return false
    }

    private static func isOneEditAway(
        _ first: String,
        _ second: String
    ) -> Bool {
        let a = Array(first)
        let b = Array(second)

        guard abs(a.count - b.count) <= 1 else {
            return false
        }

        var i = 0
        var j = 0
        var edits = 0

        while i < a.count && j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
            } else {
                edits += 1

                if edits > 1 {
                    return false
                }

                if a.count > b.count {
                    i += 1
                } else if b.count > a.count {
                    j += 1
                } else {
                    i += 1
                    j += 1
                }
            }
        }

        edits += (a.count - i) + (b.count - j)

        return edits == 1
    }
}

