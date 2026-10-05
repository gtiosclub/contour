//
//  LabelReader.swift
//  SurfaceUnderstanding — Surface / Labels
//
//  Weeks 2–3 deliverable: "Identify basic buttons and labels" (the labels half).
//
//  Stage 3 of three. Read the text on each control.
//
//  `nil` IS A GOOD ANSWER. "There is a button here and we cannot read it" is
//  shippable — Experience announces unlabelled controls positionally ("top-left
//  button"). Guessing a label the user then presses is far worse than admitting
//  you could not read it.
//

import ContourCore
import CoreGraphics
import Foundation
import Vision

/// Stage 3 — read the labels.
public struct LabelReader: Sendable {

    public init() {}

    /// Read the text inside each of `regions` on the rectified panel.
    ///
    /// Text is assigned word by word: each word goes to the region that
    /// contains its centre in panel space. Vision often reads labels that sit
    /// close together on one row as a single line ("Add 30 Sec Start Stop"), so
    /// assigning whole lines would hand every word to one button. A region with
    /// nothing inside takes the line printed just below it, because many panels
    /// print the label under the key ("START" under a ▷ key).
    ///
    /// - Returns: one entry per region, in the same order. `nil` where nothing
    ///   legible was found — do not invent a label to fill a gap. Words inside a
    ///   region are joined with a space in reading order.
    /// - Throws: `SurfaceUnderstandingError`.
    public func readLabels(
        in photo: PanelPhoto,
        panel: PanelQuad,
        regions: [PanelRect]
    ) async throws -> [String?] {
        try await read(in: photo, panel: panel, regions: regions).labels
    }

    /// The labels for `regions`, plus the text that belongs to none of them.
    struct Reading {
        var labels: [String?]
        /// Labels printed on the panel with no detected key around them, each
        /// with the area it covers. On a flat membrane keypad the label is the
        /// key, so these are buttons too.
        var textButtons: [(label: String, bounds: PanelRect)]
        /// Regions holding several separate labels: a frame around a group of
        /// keys, not a key. Their words went to `textButtons` instead.
        var frames: Set<Int> = []
    }

    /// One pass of text recognition, shared by the labels and the text-only
    /// buttons.
    func read(in photo: PanelPhoto, panel: PanelQuad, regions: [PanelRect]) async throws -> Reading {
        guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled }

        let image = try photo.cgImage()

        let observations: [VNRecognizedTextObservation]
        do {
            observations = try recognizeText(in: image, level: .accurate)
        } catch {
            // On macOS/iOS 27 the neural model behind `.accurate` sometimes
            // fails to load (e5rtError, "precompiled compute operation"), and
            // once it fails it keeps failing for the rest of the process.
            // `.fast` doesn't use that model. It can misread a letter on small
            // text, but a label on the right button with a typo beats no
            // labels at all.
            do {
                observations = try recognizeText(in: image, level: .fast)
            } catch {
                throw SurfaceUnderstandingError.underlying(error.localizedDescription)
            }
        }

        guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled }

        let words = locateWords(in: observations, panel: panel)
        let assigned = Self.assign(words, to: regions)
        return Reading(
            labels: assigned.labels,
            textButtons: Self.textButtons(from: assigned.unused),
            frames: assigned.frames
        )
    }

    func recognizeText(
        in image: CGImage,
        level: VNRequestTextRecognitionLevel
    ) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    // MARK: - Words

    /// One recognised word, placed in panel space (y down).
    struct Word: Equatable {
        let text: String
        let left: Double
        let right: Double
        let top: Double
        let bottom: Double

        var centre: PanelPoint { PanelPoint(x: (left + right) / 2, y: (top + bottom) / 2) }
        var height: Double { bottom - top }
    }

    /// Every word Vision read, with its box in panel space.
    ///
    /// Uses the word's own box when Vision can give one, and falls back to the
    /// whole line's box when it can't.
    func locateWords(in observations: [VNRecognizedTextObservation], panel: PanelQuad) -> [Word] {
        let detector = PanelDetector()
        var words: [Word] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string

            for token in text.split(whereSeparator: \.isWhitespace) {
                let range = token.startIndex..<token.endIndex
                let box = (try? candidate.boundingBox(for: range))?.boundingBox
                    ?? observation.boundingBox

                // Vision boxes are bottom-left origin, y up. Flip to our image
                // space (top-left, y down), then rectify into panel space.
                let corners = [
                    (box.minX, box.minY), (box.maxX, box.minY),
                    (box.minX, box.maxY), (box.maxX, box.maxY),
                ].map { detector.rectify(ImagePoint(x: $0.0, y: 1 - $0.1), within: panel) }

                words.append(Word(
                    text: String(token),
                    left: corners.map(\.x).min() ?? .nan,
                    right: corners.map(\.x).max() ?? .nan,
                    top: corners.map(\.y).min() ?? .nan,
                    bottom: corners.map(\.y).max() ?? .nan
                ))
            }
        }
        return words
    }

    // MARK: - Assigning words to keys

    /// Each region's label, and the words no region took.
    ///
    /// First every word goes to the region containing its centre. A region
    /// whose words form several separate labels is a frame around a group of
    /// keys, so it gives its words back. Then a region that got nothing takes
    /// the nearest line printed just below it: within three quarters of the
    /// region's height, and under it horizontally. That line can come from a
    /// box the detector drew tightly around the word itself; that box is the
    /// label, not a key, so it's dropped too.
    static func assign(_ words: [Word], to regions: [PanelRect]) -> (labels: [String?], unused: [Word], frames: Set<Int>) {
        var taken = Array(repeating: [Word](), count: regions.count)
        var unused: [Word] = []

        for word in words {
            if let index = regions.firstIndex(where: { $0.contains(word.centre) }) {
                taken[index].append(word)
            } else {
                unused.append(word)
            }
        }

        var frames = Set<Int>()
        for index in regions.indices where groups(of: taken[index]).count > 1 {
            frames.insert(index)
            unused += taken[index]
            taken[index] = []
        }

        // A box whose one word fills most of it is that word, not a key.
        func hugsItsWord(_ index: Int) -> Bool {
            guard taken[index].count == 1, let word = taken[index].first else { return false }
            let wordArea = (word.right - word.left) * (word.bottom - word.top)
            return wordArea >= regions[index].width * regions[index].height * 0.4
        }

        for (index, region) in regions.enumerated() where taken[index].isEmpty && !frames.contains(index) {
            let wordBoxes = regions.indices.filter { $0 != index && !frames.contains($0) && hugsItsWord($0) }
            let candidates = unused + wordBoxes.flatMap { taken[$0] }

            let slack = region.width * 0.25
            let below = candidates.filter { word in
                word.centre.x >= region.minX - slack && word.centre.x <= region.maxX + slack
                    && word.top >= region.maxY - region.height * 0.1
                    && word.top <= region.maxY + region.height * 0.75
            }
            guard let nearest = below.min(by: { $0.top < $1.top }) else { continue }
            let line = below.filter { $0.top < nearest.bottom && nearest.top < $0.bottom }
            taken[index] = line
            unused.removeAll { word in line.contains(word) }
            for box in wordBoxes where taken[box].contains(where: line.contains) {
                frames.insert(box)
                taken[box] = []
            }
        }

        let labels = taken.map { words in
            words.isEmpty ? nil : readingOrder(words).map(\.text).joined(separator: " ")
        }
        return (labels, unused, frames)
    }

    // MARK: - Text without a key

    /// Labels made from words that belong to no detected key.
    ///
    /// Words join one label when they sit on one line with a small gap ("Add 30
    /// Sec"), or are stacked tightly above each other ("Dinner" over "Plate").
    /// Labels a normal key-width apart stay separate. Each label's area is its
    /// words' box plus a little margin.
    static func textButtons(from words: [Word]) -> [(label: String, bounds: PanelRect)] {
        let words = words.filter { word in
            word.text.contains { $0.isLetter || $0.isNumber }
                && [word.left, word.right, word.top, word.bottom].allSatisfy(\.isFinite)
        }

        return groups(of: words).map { group in
            let margin = group.map(\.height).max()! * 0.15
            let minX = group.map(\.left).min()! - margin, maxX = group.map(\.right).max()! + margin
            let minY = group.map(\.top).min()! - margin, maxY = group.map(\.bottom).max()! + margin
            return (
                label: readingOrder(group).map(\.text).joined(separator: " "),
                bounds: PanelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            )
        }
        .sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
    }

    /// The words split into labels: words that belong together end up in one
    /// group.
    static func groups(of words: [Word]) -> [[Word]] {
        var parent = Array(words.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in words.indices {
            for j in words.indices where j > i && belongTogether(words[i], words[j]) {
                parent[root(j)] = root(i)
            }
        }
        return Dictionary(grouping: words.indices, by: root).values.map { $0.map { words[$0] } }
    }

    /// On one line with a word-sized gap, or stacked as the two lines of one
    /// label.
    ///
    /// Measured from word centres against the smaller word's height, because
    /// Vision pads some word boxes far more than others: on real panels two
    /// lines of one label sit 1–1.5 heights apart and separate keys 1.9 or more.
    private static func belongTogether(_ a: Word, _ b: Word) -> Bool {
        let height = min(a.height, b.height)
        let rise = abs(a.centre.y - b.centre.y)
        if rise <= height * 0.5 {
            let gap = max(a.left, b.left) - min(a.right, b.right)
            return gap <= height * 0.6
        }

        let overlap = min(a.right, b.right) - max(a.left, b.left)
        let narrower = min(a.right - a.left, b.right - b.left)
        return overlap >= narrower * 0.5 && rise <= height * 1.6
    }

    /// Words in reading order: rows top to bottom, left to right within a row.
    ///
    /// Two words share a row when their vertical extents overlap, so words on
    /// one line stay in left-to-right order even if Vision puts their centres a
    /// hair apart in y.
    static func readingOrder(_ words: [Word]) -> [Word] {
        var rows: [[Word]] = []
        for word in words.sorted(by: { $0.centre.y < $1.centre.y }) {
            if let last = rows.last?.last,
               word.top < last.bottom, last.top < word.bottom {
                rows[rows.count - 1].append(word)
            } else {
                rows.append([word])
            }
        }
        return rows.flatMap { $0.sorted { $0.centre.x < $1.centre.x } }
    }
}
