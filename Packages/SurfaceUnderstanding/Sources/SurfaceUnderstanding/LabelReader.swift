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
@preconcurrency import Vision

/// Stage 3 — read the labels.

public struct LabelReader: Sendable {

    public init() {}

    /// Read the text inside each of `regions` on the rectified panel.
    ///
    /// Text is assigned word by word: each word goes to the region that
    /// contains its centre in panel space. Vision often reads labels that sit
    /// close together on one row as a single line ("Add 30 Sec Start Stop"), so
    /// assigning whole lines would hand every word to one button.
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

        guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled}

        let image = try photo.cgImage()

        // Start accurate OCR in the background.
        let accurateTask = Task {
            try await recognizeText(
                in: image,
                level: .accurate
            )
        }

        // Always give accurate OCR the full 2 seconds.
        try await Task.sleep(for: .seconds(2))

        let observations: [VNRecognizedTextObservation]

        if let results = try? await accurateTask.value,
           !results.isEmpty {

            // Accurate OCR produced results.
            observations = results

        } else {

            // Accurate OCR did not produce results,
            // so fall back to fast OCR.
            accurateTask.cancel()

            guard !Task.isCancelled else {
                throw SurfaceUnderstandingError.cancelled
            }
            // On macOS/iOS 27 the neural model behind `.accurate` sometimes
            // fails to load (e5rtError, "precompiled compute operation"), and
            // once it fails it keeps failing for the rest of the process.
            // `.fast` doesn't use that model. It can misread a letter on small
            // text, but a label on the right button with a typo beats no
            // labels at all.
            observations = try await recognizeText(
                in: image,
                level: .fast
            )
        }

        guard !Task.isCancelled else {
            throw SurfaceUnderstandingError.cancelled
        }

        let words = locateWords(
            in: observations,
            panel: panel
        )

        return regions.map { region in

            let inside = words.filter {
                region.contains($0.centre)
            }

            guard !inside.isEmpty else {
                return nil
            }

            return readingOrder(inside)
                .map(\.text)
                .joined(separator: " ")
        }
    }

    // MARK: - Vision OCR

    /// Runs Vision's synchronous OCR request on a background queue.
    ///
    /// The Vision request and handler are created and used entirely inside
    /// the background queue so that the non-Sendable Vision types do not
    /// cross Swift concurrency boundaries.
    private func recognizeText(
        in image: CGImage,
        level: VNRequestTextRecognitionLevel
    ) async throws -> [VNRecognizedTextObservation] {

        try await withCheckedThrowingContinuation { continuation in

            DispatchQueue.global(qos: .userInitiated).async {

                let request = VNRecognizeTextRequest()

                request.recognitionLevel = level
                request.usesLanguageCorrection = false

                let handler = VNImageRequestHandler(
                    cgImage: image,
                    options: [:]
                )

                do {
                    try handler.perform([request])

                    continuation.resume(
                        returning: request.results ?? []
                    )

                } catch {
                    continuation.resume(
                        throwing: error
                    )
                }
            }
        }
    }

    // MARK: - Words

    /// One recognised word, placed in panel space.
    private struct Word {

        let text: String
        let centre: PanelPoint

        /// Top and bottom of the word in panel space, y down.
        let top: Double
        let bottom: Double
    }

    /// Every word Vision read, with its centre and vertical extent in panel space.
    ///
    /// Uses the word's own box when Vision can give one, and falls back to the
    /// whole line's box when it can't.
    private func locateWords(
        in observations: [VNRecognizedTextObservation],
        panel: PanelQuad
    ) -> [Word] {

        let detector = PanelDetector()
        var words: [Word] = []

        for observation in observations {

            guard let candidate = observation.topCandidates(1).first else {
                continue
            }

            let text = candidate.string

            for token in text.split(
                whereSeparator: \.isWhitespace
            ) {

                let range = token.startIndex..<token.endIndex

                let box =
                    (try? candidate.boundingBox(for: range))?.boundingBox
                    ?? observation.boundingBox

                // Vision boxes are bottom-left origin, y up. Flip to our image
                // space (top-left, y down), then rectify into panel space.
                func panelPoint(
                    _ x: CGFloat,
                    _ visionY: CGFloat
                ) -> PanelPoint {

                    detector.rectify(
                        ImagePoint(
                            x: x,
                            y: 1 - visionY
                        ),
                        within: panel
                    )
                }

                let corners = [
                    panelPoint(box.minX, box.minY),
                    panelPoint(box.maxX, box.minY),
                    panelPoint(box.minX, box.maxY),
                    panelPoint(box.maxX, box.maxY)
                ]
                .map(\.y)

                words.append(
                    Word(
                        text: String(token),
                        centre: panelPoint(
                            box.midX,
                            box.midY
                        ),
                        top: corners.min() ?? .nan,
                        bottom: corners.max() ?? .nan
                    )
                )
            }
        }

        return words
    }

    /// Words in reading order: rows top to bottom, left to right within a row.
    ///
    /// Two words share a row when their vertical extents overlap, so words on
    /// one line stay in left-to-right order even if Vision puts their centres a
    /// hair apart in y.
    private func readingOrder(
        _ words: [Word]
    ) -> [Word] {

        var rows: [[Word]] = []

        for word in words.sorted(
            by: { $0.centre.y < $1.centre.y }
        ) {

            if let last = rows.last?.last,
               word.top < last.bottom,
               last.top < word.bottom {

                rows[rows.count - 1].append(word)

            } else {

                rows.append([word])
            }
        }

        return rows.flatMap {
            $0.sorted {
                $0.centre.x < $1.centre.x
            }
        }
    }
}
