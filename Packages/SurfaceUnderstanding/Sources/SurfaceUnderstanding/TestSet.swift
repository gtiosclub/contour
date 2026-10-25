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

/// The scoreboard measurements for one labelled photo.
public struct ScoreboardResult: Hashable, Sendable {

    public enum Panel: String, Hashable, Sendable {
        case quad
        case fullFrame = "full frame"
        case none
    }

    public enum Start: Hashable, Sendable, CustomStringConvertible {
        case rightKey
        case wrongKey(String?)
        case notFound

        public var description: String {
            switch self {
            case .rightKey:
                return "right key"
            case .wrongKey(let label):
                return "wrong key (\(label ?? "no key"))"
            case .notFound:
                return "not found"
            }
        }
    }

    public var photo: String
    public var panel: Panel
    public var labelledCount: Int
    public var detectedCount: Int
    public var centerHits: Int
    public var iouHits: Int
    public var correctLabels: Int
    public var start: Start
    public var seconds: Double

    public var recall: Double {
        labelledCount == 0 ? 0 : Double(centerHits) / Double(labelledCount)
    }

    public var precision: Double? {
        detectedCount == 0 ? nil : Double(centerHits) / Double(detectedCount)
    }

    public var labelAccuracy: Double? {
        centerHits == 0 ? nil : Double(correctLabels) / Double(centerHits)
    }
}

/// Corpus totals, calculated from summed counts rather than averaged percentages.
public struct ScoreboardTotals: Hashable, Sendable {
    public var labelledCount: Int
    public var detectedCount: Int
    public var centerHits: Int
    public var iouHits: Int
    public var correctLabels: Int
    public var startRightKey: Int
    public var startWrongKey: Int
    public var startNotFound: Int
    public var seconds: Double

    public init(_ results: [ScoreboardResult]) {
        labelledCount = results.reduce(0) { $0 + $1.labelledCount }
        detectedCount = results.reduce(0) { $0 + $1.detectedCount }
        centerHits = results.reduce(0) { $0 + $1.centerHits }
        iouHits = results.reduce(0) { $0 + $1.iouHits }
        correctLabels = results.reduce(0) { $0 + $1.correctLabels }
        startRightKey = results.count { $0.start == .rightKey }
        startWrongKey = results.count {
            if case .wrongKey = $0.start { return true }
            return false
        }
        startNotFound = results.count { $0.start == .notFound }
        seconds = results.reduce(0) { $0 + $1.seconds }
    }

    public var recall: Double {
        labelledCount == 0 ? 0 : Double(centerHits) / Double(labelledCount)
    }

    public var precision: Double? {
        detectedCount == 0 ? nil : Double(centerHits) / Double(detectedCount)
    }

    public var labelAccuracy: Double? {
        centerHits == 0 ? nil : Double(correctLabels) / Double(centerHits)
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

    /// Score a detector result after mapping it into the labelled panel's space.
    public static func scoreboardResult(
        photo: String,
        detected: SurfaceMap,
        detectedPanel: PanelQuad?,
        sample: LabelledSample,
        seconds: Double
    ) -> ScoreboardResult {
        let mappedAllButtons: [SurfaceMap.Button]
        let panel: ScoreboardResult.Panel
        if let detectedPanel {
            panel = detectedPanel == .fullFrame ? .fullFrame : .quad
            mappedAllButtons = detected.buttons.map { button in
                SurfaceMap.Button(
                    label: button.label,
                    bounds: bounds(button.bounds, from: detectedPanel, to: sample.panel),
                    confidence: button.confidence
                )
            }
        } else {
            panel = .none
            mappedAllButtons = []
        }

        let mapped = SurfaceMap(buttons: mappedAllButtons, confidence: detected.confidence)
        let centerMatches = centerMatches(detected: mapped.buttons, expected: sample.expected.buttons)
        let overlapMatches = iouMatches(detected: mapped.buttons, expected: sample.expected.buttons)
        let correctLabels = centerMatches.count { match in
            labelsMatch(
                detected: mapped.buttons[match.detected].label,
                expected: sample.expected.buttons[match.expected].label
            )
        }

        return ScoreboardResult(
            photo: photo,
            panel: panel,
            labelledCount: sample.expected.buttons.count,
            detectedCount: mapped.buttons.count,
            centerHits: centerMatches.count,
            iouHits: overlapMatches.count,
            correctLabels: correctLabels,
            start: startResult(in: mapped, expected: sample.expected),
            seconds: seconds
        )
    }

    /// Move a detector-space rectangle through upright image space into another panel.
    public static func bounds(
        _ bounds: PanelRect,
        from source: PanelQuad,
        to destination: PanelQuad
    ) -> PanelRect {
        let detector = PanelDetector()

        // `rectify` maps image → panel. Build the inverse homography by mapping
        // the image unit square into `source`, then rectifying panel points within it.
        func sourcePanelPoint(_ x: Double, _ y: Double) -> ImagePoint {
            let point = detector.rectify(ImagePoint(x: x, y: y), within: source)
            return ImagePoint(x: point.x, y: point.y)
        }
        let inverseSource = PanelQuad(
            topLeft: sourcePanelPoint(0, 0),
            topRight: sourcePanelPoint(1, 0),
            bottomRight: sourcePanelPoint(1, 1),
            bottomLeft: sourcePanelPoint(0, 1)
        )

        let corners = [
            PanelPoint(x: bounds.minX, y: bounds.minY),
            PanelPoint(x: bounds.maxX, y: bounds.minY),
            PanelPoint(x: bounds.maxX, y: bounds.maxY),
            PanelPoint(x: bounds.minX, y: bounds.maxY),
        ].map { point -> PanelPoint in
            let image = detector.rectify(
                ImagePoint(x: point.x, y: point.y),
                within: inverseSource
            )
            return detector.rectify(
                ImagePoint(x: image.x, y: image.y),
                within: destination
            )
        }

        let minX = corners.map(\.x).min() ?? .nan
        let maxX = corners.map(\.x).max() ?? .nan
        let minY = corners.map(\.y).min() ?? .nan
        let maxY = corners.map(\.y).max() ?? .nan
        return PanelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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

    private static func centerMatches(
        detected: [SurfaceMap.Button],
        expected: [SurfaceMap.Button]
    ) -> [(detected: Int, expected: Int)] {
        var candidates: [(detected: Int, expected: Int, distance: Double)] = []
        for (detectedIndex, detectedButton) in detected.enumerated() {
            for (expectedIndex, expectedButton) in expected.enumerated()
            where expectedButton.bounds.contains(detectedButton.bounds.center) {
                candidates.append((
                    detected: detectedIndex,
                    expected: expectedIndex,
                    distance: detectedButton.bounds.center.distance(to: expectedButton.bounds.center)
                ))
            }
        }
        candidates.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.detected != $1.detected { return $0.detected < $1.detected }
            return $0.expected < $1.expected
        }
        return oneToOne(candidates.map { ($0.detected, $0.expected) })
    }

    private static func iouMatches(
        detected: [SurfaceMap.Button],
        expected: [SurfaceMap.Button]
    ) -> [(detected: Int, expected: Int)] {
        var candidates: [(detected: Int, expected: Int, overlap: Double)] = []
        for (detectedIndex, detectedButton) in detected.enumerated() {
            for (expectedIndex, expectedButton) in expected.enumerated() {
                let overlap = iou(detectedButton.bounds, expectedButton.bounds)
                if overlap >= 0.5 {
                    candidates.append((detectedIndex, expectedIndex, overlap))
                }
            }
        }
        candidates.sort {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.detected != $1.detected { return $0.detected < $1.detected }
            return $0.expected < $1.expected
        }
        return oneToOne(candidates.map { ($0.detected, $0.expected) })
    }

    private static func oneToOne(
        _ candidates: [(detected: Int, expected: Int)]
    ) -> [(detected: Int, expected: Int)] {
        var usedDetected = Set<Int>()
        var usedExpected = Set<Int>()
        var matches: [(detected: Int, expected: Int)] = []
        for candidate in candidates
        where !usedDetected.contains(candidate.detected)
            && !usedExpected.contains(candidate.expected) {
            usedDetected.insert(candidate.detected)
            usedExpected.insert(candidate.expected)
            matches.append(candidate)
        }
        return matches
    }

    private static func startResult(
        in detected: SurfaceMap,
        expected: SurfaceMap
    ) -> ScoreboardResult.Start {
        guard let match = TargetMatcher().match("Start", in: detected) else {
            return .notFound
        }
        let containing = expected.buttons
            .filter { $0.bounds.contains(match.button.bounds.center) }
            .min {
                match.button.bounds.center.distance(to: $0.bounds.center)
                    < match.button.bounds.center.distance(to: $1.bounds.center)
            }
        guard let containing else { return .wrongKey(nil) }
        return labelVariants(containing.label).contains("start")
            ? .rightKey
            : .wrongKey(containing.label)
    }

    private static func labelsMatch(detected: String?, expected: String?) -> Bool {
        guard let detected else { return false }
        let normalizedDetected = normalizedForScoreboard(detected)
        return !normalizedDetected.isEmpty
            && labelVariants(expected).contains(normalizedDetected)
    }

    private static func labelVariants(_ label: String?) -> Set<String> {
        guard let label else { return [] }
        var variants = Set([normalizedForScoreboard(label)])
        variants.formUnion(label.split(separator: "/").map {
            normalizedForScoreboard(String($0))
        })
        return variants.filter { !$0.isEmpty }
    }

    private static func normalizedForScoreboard(_ label: String) -> String {
        String(label.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
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
