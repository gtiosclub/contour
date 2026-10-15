//
//  LabelReaderTests.swift
//  SurfaceUnderstandingTests — Surface / Labels
//
//  The two cases the lane test can't see: a panel that doesn't fill the photo,
//  and labels close enough together that Vision reads them as one line.
//

import ContourCore
import Foundation
import Testing
@testable import SurfaceUnderstanding

private actor FastCallCounter {
    private var calls = 0
    func record() {
        calls += 1
    }
    func count() -> Int {
        calls
    }
}

private enum RecognizerTestError: Error {
    case expected
}

@Test("Labels: read through the real quad when the panel doesn't fill the photo",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func labelReaderUsesTheQuad() async throws {
    let (photo, quad) = try SyntheticPanel.insetPhoto()
    let regions = SyntheticPanel.expected.buttons.map(\.bounds)

    let labels = try await LabelReader().readLabels(in: photo, panel: quad, regions: regions)

    let expected = SyntheticPanel.expected.buttons.map(\.label)
    #expect(TextRecognitionCheck.labelsMatch(labels, expected), "read \(labels), expected \(expected)")
}

@Test("Labels: labels close together on one row each go to their own button",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func labelReaderSplitsAMergedLine() async throws {
    let (photo, regions, expected) = try SyntheticPanel.tightRowPhoto()

    let labels = try await LabelReader().readLabels(in: photo, panel: .fullFrame, regions: regions)

    // Vision reads this row as "Popcorn Beverage Defrost". Assigning that whole
    // line by its centre would give [nil, "Popcorn Beverage Defrost", nil].
    #expect(TextRecognitionCheck.labelsMatch(labels, expected), "read \(labels), expected \(expected)")
}

@Test("Slow accurate recognition falls back to fast")
func slowAccurateFallsBackToFast() async throws {
    let photo = try SyntheticPanel.photo()
    let image = try photo.cgImage()
    let counter = FastCallCounter()

    let result = try await LabelReader.recognizeText(
        in: image,
        budget: .milliseconds(100),
        using: { _, level in
            if level == .accurate {
                try await Task.sleep(for: .seconds(10))
            } else {
                await counter.record()
            }

            return []
        }
    )

    #expect(result.isEmpty)
    let fastCalls = await counter.count()
    #expect(fastCalls == 1)
}

@Test("Quick accurate recognition does not call fast")
func quickAccurateSkipsFast() async throws {
    let photo = try SyntheticPanel.photo()
    let image = try photo.cgImage()
    let counter = FastCallCounter()

    let result = try await LabelReader.recognizeText(
        in: image,
        budget: .seconds(2),
        using: { _, level in
            if level == .accurate {
                try await Task.sleep(for: .milliseconds(50))
            } else {
                await counter.record()
            }

            return []
        }
    )

    #expect(result.isEmpty)
    let fastCalls = await counter.count()
    #expect(fastCalls == 0)
}

@Test("Accurate recognition error falls back to fast")
func accurateErrorFallsBackToFast() async throws {
    let photo = try SyntheticPanel.photo()
    let image = try photo.cgImage()
    let counter = FastCallCounter()

    let result = try await LabelReader.recognizeText(
        in: image,
        budget: .seconds(2),
        using: { _, level in
            if level == .accurate {
                throw RecognizerTestError.expected
            }

            await counter.record()
            return []
        }
    )

    #expect(result.isEmpty)

    let fastCalls = await counter.count()
    #expect(fastCalls == 1)
}

@Test("Accurate and fast errors become an underlying error")
func bothRecognizersFail() async throws {
    let photo = try SyntheticPanel.photo()
    let reader = LabelReader(
        recognizer: { _, _ in
            throw RecognizerTestError.expected
        }
    )

    do {
        _ = try await reader.read(
            in: photo,
            panel: .fullFrame,
            regions: []
        )
        Issue.record("Expected recognition to fail")
    } catch let error as SurfaceUnderstandingError {
        if case .underlying = error {
            // Expected: both recognition attempts failed.
        } else {
            Issue.record("Expected .underlying, got \(error)")
        }
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("Cancelling recognition produces a cancelled error")
func cancellingRecognition() async throws {
    let photo = try SyntheticPanel.photo()
    let reader = LabelReader(
        recognizer: { _, _ in
            try await Task.sleep(for: .seconds(10))
            return []
        }
    )

    let task = Task {
        try await reader.read(
            in: photo,
            panel: .fullFrame,
            regions: []
        )
    }

    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected recognition to be cancelled")
    } catch let error as SurfaceUnderstandingError {
        if case .cancelled = error {
            // Expected.
        } else {
            Issue.record("Expected .cancelled, got \(error)")
        }
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
