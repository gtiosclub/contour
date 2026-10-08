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
//  COORDINATES: ground-truth bounds are in normalized panel space — (0,0)
//  top-left, y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// One hand-labelled photo: what a human says is on this panel.
public struct LabelledSample: Identifiable, Hashable, Sendable, Codable {

    /// Stable name for the sample — use the image filename.
    public var id: String

    /// What kind of appliance, for slicing results ("microwave", "lift").
    public var appliance: String

    /// Lighting the photo was taken in, for slicing results. Weeks 6–7 test
    /// across at least two lighting conditions, so record it now.
    public var lighting: String

    /// The image-space outline used when the button boxes were labelled.
    public var panel: PanelQuad

    /// The truth: what a human says is on this panel, in panel space.
    public var expected: SurfaceMap

    public init(
        id: String,
        appliance: String,
        lighting: String,
        panel: PanelQuad,
        expected: SurfaceMap
    ) {
        self.id = id
        self.appliance = appliance
        self.lighting = lighting
        self.panel = panel
        self.expected = expected
    }
}

public enum TestSetError: Error, Equatable, Sendable {
    case missingLabelsDirectory
    case unreadableLabelsDirectory(String)
    case malformedPanel(photo: String)
    case outOfRangePanel(photo: String)
    case malformedBounds(photo: String, buttonIndex: Int)
    case outOfRangeBounds(photo: String, buttonIndex: Int)
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

/// The hand-labelled corpus and the scoring that runs against it.
public enum TestSet {

    /// Load the checked-in answer keys from a Swift Package test bundle.
    ///
    /// The caller supplies `Bundle.module`, keeping the corpus out of the app
    /// bundle and avoiding source-tree paths that do not exist on a device.
    public static func loadSamples(from bundle: Bundle) throws -> [LabelledSample] {
        guard let directory = bundle.url(
            forResource: "labels",
            withExtension: nil,
            subdirectory: "TestSet"
        ) else {
            throw TestSetError.missingLabelsDirectory
        }
        return try loadSamples(from: directory)
    }

    /// Load every JSON answer key in a directory, sorted by photo filename.
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
                return try JSONDecoder().decode(AnswerKey.self, from: data).sample()
            }
    }

    /// Score one detection against its ground truth.
    ///
    /// - Parameter overlapThreshold: how much a detected box must overlap a
    ///   ground-truth box to count as the same button, as intersection over
    ///   union. `0.5` is the usual starting point.
    public static func score(
        detected: SurfaceMap,
        against expected: SurfaceMap,
        overlapThreshold: Double = 0.5
    ) -> SampleScore {
        var candidates: [(expected: Int, detected: Int, overlap: Double)] = []

        for (expectedIndex, expectedButton) in expected.buttons.enumerated() {
            for (detectedIndex, detectedButton) in detected.buttons.enumerated() {
                candidates.append((
                    expected: expectedIndex,
                    detected: detectedIndex,
                    overlap: iou(expectedButton.bounds, detectedButton.bounds)
                ))
            }
        }

        candidates.sort { $0.overlap > $1.overlap }

        var usedExpected = Set<Int>()
        var usedDetected = Set<Int>()
        var matches: [(expected: SurfaceMap.Button, detected: SurfaceMap.Button)] = []

        for candidate in candidates where candidate.overlap >= overlapThreshold {
            guard !usedExpected.contains(candidate.expected),
                  !usedDetected.contains(candidate.detected) else {
                continue
            }

            usedExpected.insert(candidate.expected)
            usedDetected.insert(candidate.detected)
            matches.append((
                expected: expected.buttons[candidate.expected],
                detected: detected.buttons[candidate.detected]
            ))
        }

        let labelledMatches = matches.compactMap { match -> Bool? in
            guard let expectedLabel = match.expected.label else { return nil }
            guard let detectedLabel = match.detected.label else { return false }
            return normalized(expectedLabel) == normalized(detectedLabel)
        }

        return SampleScore(
            recall: fraction(matches.count, outOf: expected.buttons.count),
            precision: fraction(matches.count, outOf: detected.buttons.count),
            labelAccuracy: fraction(labelledMatches.count(where: { $0 }), outOf: labelledMatches.count)
        )
    }

    /// Intersection over union for two normalized panel-space rectangles.
    static func iou(_ a: PanelRect, _ b: PanelRect) -> Double {
        let left = max(a.minX, b.minX)
        let right = min(a.maxX, b.maxX)
        let top = max(a.minY, b.minY)
        let bottom = min(a.maxY, b.maxY)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func normalized(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func fraction(_ numerator: Int, outOf denominator: Int) -> Double {
        denominator == 0 ? 1 : Double(numerator) / Double(denominator)
    }
}

private struct AnswerKey: Decodable {
    var photo: String
    var panel: [[Double]]
    var buttons: [AnswerKeyButton]

    func sample() throws -> LabelledSample {
        let panel = try panelQuad()
        let mappedButtons = try buttons.enumerated().map { index, button in
            try button.surfaceMapButton(photo: photo, index: index)
        }
        let appliance = photo.split(separator: "-").first.map(String.init) ?? "unknown"
        return LabelledSample(
            id: photo,
            appliance: appliance,
            lighting: "unspecified",
            panel: panel,
            expected: SurfaceMap(buttons: mappedButtons, confidence: 1)
        )
    }

    private func panelQuad() throws -> PanelQuad {
        guard panel.count == 4, panel.allSatisfy({ $0.count == 2 }) else {
            throw TestSetError.malformedPanel(photo: photo)
        }
        let points = panel.map { ImagePoint(x: $0[0], y: $0[1]) }
        guard points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw TestSetError.outOfRangePanel(photo: photo)
        }
        return PanelQuad(
            topLeft: points[0],
            topRight: points[1],
            bottomRight: points[2],
            bottomLeft: points[3]
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
