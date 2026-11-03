//
//  LabelReaderWarmUpTests.swift
//  SurfaceUnderstandingTests — Surface / Labels
//
//  The warm-up with a stand-in for Vision, so these run on CI, and once for real
//  where Vision works.
//

import ContourCore
import CoreGraphics
import Foundation
import Testing
import Vision
import os
@testable import SurfaceUnderstanding

private typealias Level = RecognizeTextRequest.RecognitionLevel

private struct Call: Sendable {
    let level: Level
    let width: Int
    let priority: TaskPriority
}

/// Holds a stand-in recognizer until the test lets it go.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Which levels a stand-in was asked for.
private final class Levels: Sendable {
    private let seen = OSAllocatedUnfairLock<[Level]>(initialState: [])
    var all: [Level] { seen.withLock { $0 } }
    func add(_ level: Level) { seen.withLock { $0.append(level) } }
}

private func wordPhoto() throws -> PanelPhoto {
    let image = try #require(LabelReader.warmUpImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return PanelPhoto(data: data as Data, pixelSize: PixelSize(width: image.width, height: image.height), timestamp: .distantPast)
}

@Suite("Text model warm-up")
struct LabelReaderWarmUpTests {

    private func notLoading() -> OSAllocatedUnfairLock<Bool> { OSAllocatedUnfairLock(initialState: false) }

    @Test("Makes one .accurate call on a small image, at low priority")
    func oneAccurateCall() async throws {
        let (calls, log) = AsyncStream.makeStream(of: Call.self)
        let warmUp = LabelReader.warmUp(loading: notLoading()) { image, level in
            log.yield(Call(level: level, width: image.width, priority: Task.currentPriority))
            return []
        }
        // Read the call before waiting on the task: waiting lifts it to this test's priority.
        var iterator = calls.makeAsyncIterator()
        let call = try #require(await iterator.next())
        #expect(call.level == .accurate)
        #expect(call.width <= 480)
        #expect(call.priority <= .low)
        await warmUp.value
        log.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("Returns before the model has loaded, and only then frees .accurate")
    func loadingFlag() async {
        let gate = Gate()
        let loading = notLoading()
        // Getting past this line with the stand-in held shut is half the test.
        let warmUp = LabelReader.warmUp(loading: loading) { _, _ in
            await gate.wait()
            return []
        }
        #expect(loading.withLock { $0 }, "A scan straight after the call has to see it")
        await gate.release()
        await warmUp.value
        #expect(!loading.withLock { $0 })
    }

    @Test("A failed load only ends the warm-up, and frees .accurate")
    func failureIsHarmless() async {
        let loading = notLoading()
        let (calls, log) = AsyncStream.makeStream(of: Void.self)
        await LabelReader.warmUp(loading: loading) { _, _ in
            log.yield()
            throw SurfaceUnderstandingError.underlying("model failed")
        }.value
        log.finish()
        var count = 0
        for await _ in calls { count += 1 }
        #expect(count == 1)
        #expect(!loading.withLock { $0 })
    }

    @Test("While it loads, .accurate is refused and never reaches Vision, and .fast still works")
    func refusesAccurateWhileLoading() async throws {
        let image = try #require(LabelReader.warmUpImage())
        let loading = OSAllocatedUnfairLock(initialState: true)
        let vision = Levels()
        let standIn: LabelReader.Recognizer = { _, level in
            vision.add(level)
            return []
        }
        await #expect(throws: LabelReader.ModelLoading.self) {
            _ = try await LabelReader.recognize(image, level: .accurate, loading: loading, using: standIn)
        }
        #expect(vision.all.isEmpty)
        _ = try await LabelReader.recognize(image, level: .fast, loading: loading, using: standIn)
        #expect(vision.all == [.fast])

        loading.withLock { $0 = false }
        _ = try await LabelReader.recognize(image, level: .accurate, loading: loading, using: standIn)
        #expect(vision.all == [.fast, .accurate])
    }

    @Test("A scan during the load gets .fast labels at once, not after the 2 s budget")
    func labelsDuringLoad() async throws {
        let image = try #require(LabelReader.warmUpImage())
        let loading = OSAllocatedUnfairLock(initialState: true)
        let vision = Levels()
        let started = ContinuousClock.now
        _ = try await LabelReader.recognizeText(in: image) { image, level in
            try await LabelReader.recognize(image, level: level, loading: loading) { _, level in
                vision.add(level)
                return []
            }
        }
        #expect(vision.all == [.fast])
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("A scan during the load keeps its buttons and doesn't touch .accurate")
    func keypadDuringLoad() async throws {
        let loading = OSAllocatedUnfairLock(initialState: true)
        let vision = Levels()
        var scan = LiveSurfaceUnderstanding()
        scan.keypadReader = KeypadReader(recognizer: { image, level in
            try await LabelReader.recognize(image, level: level, loading: loading) { _, level in
                vision.add(level)
                return []
            }
        })
        let buttons = [SurfaceMap.Button(label: "Start", bounds: PanelRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), confidence: 1)]
        let started = ContinuousClock.now
        let result = try await scan.addingKeypad(to: buttons, in: try wordPhoto(), panel: .fullFrame)
        #expect(result == buttons)
        #expect(vision.all.isEmpty)
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("Vision reads the warm-up image, so all of the read runs",
          .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason), TextRecognitionCheck.timeLimit)
    func realRead() async throws {
        let image = try #require(LabelReader.warmUpImage())
        let observations = try await LabelReader.request(image, level: .accurate)
        let read = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
        #expect(read.uppercased().contains("START"))
    }
}
