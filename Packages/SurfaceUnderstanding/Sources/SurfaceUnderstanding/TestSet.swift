//
//  TestSet.swift
//  SurfaceUnderstanding — Surface / Eval & Test Set
//
//  Weeks 2–3 deliverable: "Hand-label the test set."
//
//  Every club member owes five photos of appliance panels they can reach. That
//  is the corpus. This file is how a labelled example is written down and how
//  detection is scored against it.
//
//  Scoring matters more than it sounds. Weeks 6–7 are "make recognition work
//  across different appliances", and you cannot tell whether a change helped
//  without a number. Build this early and cheaply.
//
//  Ground-truth bounds use normalized, straightened panel space: (0,0) is the
//  top-left, (1,1) is the bottom-right, and y increases downward.
//

import ContourCore
import Foundation

/// One hand-labelled photo: what a human says is on this panel.
public struct LabelledSample: Identifiable, Hashable, Sendable, Codable {

    /// Stable name for the sample — use the image filename.
    public var id: String

    /// What kind of appliance, for slicing results ("microwave", "lift").
    public var appliance: String

    /// Lighting the photo was taken in, for slicing results.
    public var lighting: String

    /// The truth: what a human says is on this panel, in panel space.
    public var expected: SurfaceMap

    public init(
        id: String,
        appliance: String,
        lighting: String,
        expected: SurfaceMap
    ) {
        self.id = id
        self.appliance = appliance
        self.lighting = lighting
        self.expected = expected
    }
}

/// How well a detected map matched the ground truth for one sample.
public struct SampleScore: Hashable, Sendable {

    /// Ground-truth buttons that were found, as a fraction of all of them.
    public var recall: Double

    /// Detected buttons that were real, as a fraction of all detections.
    public var precision: Double

    /// Of the buttons found, the fraction whose label was read correctly.
    public var labelAccuracy: Double

    public init(recall: Double, precision: Double, labelAccuracy: Double) {
        self.recall = recall
        self.precision = precision
        self.labelAccuracy = labelAccuracy
    }
}

public enum TestSetError: Error, Equatable, Sendable {
    case unreadableLabelsDirectory(String)
    case malformedBounds(photo: String, buttonIndex: Int)
    case outOfRangeBounds(photo: String, buttonIndex: Int)
}

/// The hand-labelled corpus and deterministic scoring used by evaluation tests.
public enum TestSet {

    /// A detected box must meet this intersection-over-union to count as found.
    public static let defaultOverlapThreshold = 0.5

    /// The checked-in JSON answer keys, sorted by photo filename.
    public static let samples: [LabelledSample] = {
        do {
            return try loadSamples(from: labelsDirectory)
        } catch {
            preconditionFailure("Could not load SurfaceUnderstanding test set: \(error)")
        }
    }()

    /// Load every JSON answer key in a directory.
    public static func loadSamples(from directory: URL) throws -> [LabelledSample] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw TestSetError.unreadableLabelsDirectory(directory.path)
        }

        return try files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let data = try Data(contentsOf: url)
                let answerKey = try JSONDecoder().decode(AnswerKey.self, from: data)
                return try answerKey.sample()
            }
    }

    /// Score one detection against its ground truth using one-to-one box matches.
    public static func score(
        detected: SurfaceMap,
        against expected: SurfaceMap,
        overlapThreshold: Double = defaultOverlapThreshold
    ) -> SampleScore {
        let matches = matches(
            detected: detected.buttons,
            expected: expected.buttons,
            threshold: overlapThreshold
        )
        let labelledMatches = matches.filter { expected.buttons[$0.expected].label != nil }
        let correctLabels = labelledMatches.filter { match in
            labelsMatch(
                detected.buttons[match.detected].label,
                expected.buttons[match.expected].label
            )
        }.count

        return SampleScore(
            recall: fraction(matches.count, expected.buttons.count),
            precision: fraction(matches.count, detected.buttons.count),
            labelAccuracy: fraction(correctLabels, labelledMatches.count)
        )
    }

    /// Intersection over union for two normalized panel-space boxes.
    public static func intersectionOverUnion(_ lhs: PanelRect, _ rhs: PanelRect) -> Double {
        let intersectionWidth = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let intersectionHeight = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        let intersectionArea = intersectionWidth * intersectionHeight
        let lhsArea = max(0, lhs.width) * max(0, lhs.height)
        let rhsArea = max(0, rhs.width) * max(0, rhs.height)
        let unionArea = lhsArea + rhsArea - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private static let labelsDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "TestSet/labels", directoryHint: .isDirectory)

    private struct Match {
        var detected: Int
        var expected: Int
        var overlap: Double
    }

    private static func matches(
        detected: [SurfaceMap.Button],
        expected: [SurfaceMap.Button],
        threshold: Double
    ) -> [Match] {
        var candidates: [Match] = []
        for expectedIndex in expected.indices {
            for detectedIndex in detected.indices {
                let overlap = intersectionOverUnion(
                    detected[detectedIndex].bounds,
                    expected[expectedIndex].bounds
                )
                if overlap >= threshold {
                    candidates.append(
                        Match(detected: detectedIndex, expected: expectedIndex, overlap: overlap)
                    )
                }
            }
        }
        candidates.sort { $0.overlap > $1.overlap }

        var usedDetected: Set<Int> = []
        var usedExpected: Set<Int> = []
        var result: [Match] = []
        for candidate in candidates {
            guard !usedDetected.contains(candidate.detected),
                  !usedExpected.contains(candidate.expected) else {
                continue
            }
            usedDetected.insert(candidate.detected)
            usedExpected.insert(candidate.expected)
            result.append(candidate)
        }
        return result
    }

    private static func labelsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.trimmingCharacters(in: .whitespacesAndNewlines).compare(
            rhs.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    private static func fraction(_ numerator: Int, _ denominator: Int) -> Double {
        denominator > 0 ? Double(numerator) / Double(denominator) : 0
    }
}

private struct AnswerKey: Decodable {
    var photo: String
    var buttons: [AnswerKeyButton]

    func sample() throws -> LabelledSample {
        let mappedButtons = try buttons.enumerated().map { index, button in
            try button.surfaceMapButton(photo: photo, index: index)
        }
        let appliance = photo.split(separator: "-").first.map(String.init) ?? "unknown"
        return LabelledSample(
            id: photo,
            appliance: appliance,
            lighting: "unspecified",
            expected: SurfaceMap(buttons: mappedButtons, confidence: 1)
        )
    }
}

private struct AnswerKeyButton: Decodable {
    var label: String
    var bounds: [Double]

    func surfaceMapButton(photo: String, index: Int) throws -> SurfaceMap.Button {
        guard bounds.count == 4 else {
            throw TestSetError.malformedBounds(photo: photo, buttonIndex: index)
        }
        let rect = PanelRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
        guard rect.minX >= 0, rect.minY >= 0, rect.width >= 0, rect.height >= 0,
              rect.maxX <= 1, rect.maxY <= 1 else {
            throw TestSetError.outOfRangeBounds(photo: photo, buttonIndex: index)
        }
        return SurfaceMap.Button(label: label, bounds: rect, confidence: 1)
    }
}
