//
//  TextRecognitionCheck.swift
//  SurfaceUnderstandingTests
//
//  Test support for anything that runs Vision text recognition.
//
//  On macOS 27 the neural model behind `.accurate` sometimes fails to load, and
//  LabelReader falls back to `.fast` when it does. So OCR tests:
//  - skip on CI. On GitHub's xcode-27 runner Vision text recognition either
//    throws or hangs the whole test process (the job sat for 20 minutes without
//    running a test), so it can't be trusted there. Run them on a Mac.
//  - skip when `.fast` doesn't work on the machine at all, and
//  - compare labels allowing one wrong character, because `.fast` can read
//    "Start" as "Stsrt". What they check is which button each label lands on.
//
//  The local check runs off the main thread with a time limit, so it can never
//  block the test runner.

import CoreGraphics
import CoreText
import Foundation
import Testing
import Vision

enum TextRecognitionCheck {

    /// GitHub Actions sets CI=true.
    static let onCI = ProcessInfo.processInfo.environment["CI"] != nil

    /// True when `.fast` text recognition can read a plain word here. Never
    /// touches Vision on CI.
    static let works: Bool = {
        if onCI { return false }
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            result.set(attempt(.fast))
            done.signal()
        }
        if done.wait(timeout: .now() + 90) == .timedOut { result.set("timed out after 90s") }
        let fast = result.value
        FileHandle.standardError.write(Data("TextRecognitionCheck: fast=\(fast)\n".utf8))
        return fast == "ok"
    }()

    /// The check's outcome, written by the worker thread and read by the runner.
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = "not run"
        var value: String { lock.withLock { stored } }
        func set(_ value: String) { lock.withLock { if stored == "not run" { stored = value } } }
    }

    /// Long enough for a slow first Vision call, short enough that a hang
    /// fails the test instead of stalling CI for hours.
    static let timeLimit: TimeLimitTrait = .timeLimit(.minutes(2))

    static let skipReason: Comment = "Skipped: Vision text recognition fails or hangs on CI (or doesn't work on this machine). Run swift test on a Mac."

    /// Labels match slot by slot, allowing one wrong character per label.
    ///
    /// A label on the wrong button, two labels merged into one, or words in
    /// the wrong order are all far more than one character off, so this still
    /// catches every assignment bug. It only forgives OCR spelling.
    static func labelsMatch(_ read: [String?], _ expected: [String?]) -> Bool {
        guard read.count == expected.count else { return false }
        return zip(read, expected).allSatisfy { read, expected in
            switch (read?.lowercased(), expected?.lowercased()) {
            case (nil, nil): true
            case let (read?, expected?): editDistance(read, expected) <= 1
            default: false
            }
        }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in a.indices {
            var diagonal = row[0]
            row[0] = i + 1
            for j in b.indices {
                let above = row[j + 1]
                row[j + 1] = a[i] == b[j] ? diagonal : min(diagonal, above, row[j]) + 1
                diagonal = above
            }
        }
        return row[b.count]
    }

    private static func attempt(_ level: VNRequestTextRecognitionLevel) -> String {
        guard let image = render("START") else { return "no-image" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return "threw(\(error.localizedDescription))"
        }
        let read = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return read.uppercased().contains("START") ? "ok" : "read(\"\(read)\")"
    }

    /// Black text on white, big enough that any working recogniser reads it.
    private static func render(_ text: String) -> CGImage? {
        let width = 480, height = 160
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]))
        ctx.textPosition = CGPoint(x: 40, y: 55)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
