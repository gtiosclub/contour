//
//  LabelReader+WarmUp.swift
//  SurfaceUnderstanding — Surface / Labels
//
//  Loads Vision's `.accurate` model when the app opens, so a scan doesn't have to.
//
//  On a fresh install that load took 25 to 55 s on a Mac. KeypadReader gives up on
//  its read after about 2 s, so until the model is in, a scan gets no digit keys.
//
//  ONE LOAD AT A TIME. While the warm-up is loading, a scan doesn't ask for
//  `.accurate`: its labels come from `.fast` and it gets no keypad, which is what
//  it would have got anyway, only sooner. When scans did ask and then gave up at
//  their time caps, the load failed with an e5rt error and digit keys didn't come
//  back while we watched (2 of 2 runs on a Mac, 3 to 5 minutes each), and a scan
//  could hang for over a minute.
//

import CoreGraphics
import CoreText
import Foundation
import OSLog
import Vision
import os

extension LabelReader {

    /// Thrown instead of asking for `.accurate` while the warm-up is loading it.
    struct ModelLoading: Error {}

    /// True from when the warm-up starts until it ends, however it ends.
    static let modelLoading = OSAllocatedUnfairLock(initialState: false)

    /// Whether the warm-up is still loading the model. A scan started now gets no
    /// digit keys, so the app can say to wait instead of to aim again.
    public static var isWarmingUp: Bool { modelLoading.withLock { $0 } }

    /// Starts loading the `.accurate` model at low priority and returns at once.
    ///
    /// Call it once, when the app opens. Nothing waits on it. If it fails, that's
    /// only logged, and a scan goes back to trying `.accurate` itself.
    @discardableResult
    public static func warmUp() -> Task<Void, Never> {
        warmUp(loading: modelLoading, using: request)
    }

    static func warmUp(loading: OSAllocatedUnfairLock<Bool>, using recognizer: @escaping Recognizer) -> Task<Void, Never> {
        // Set here, not in the task, so a scan can't get in before the task has started.
        loading.withLock { $0 = true }
        return Task.detached(priority: .low) {
            defer { loading.withLock { $0 = false } }
            let logger = Logger(subsystem: "edu.gatech.contour", category: "SurfaceScan")
            let started = ContinuousClock.now
            do {
                guard let image = warmUpImage() else {
                    logger.error("Text model warm-up: couldn't draw its image")
                    return
                }
                let observations = try await recognizer(image, .accurate)
                logger.info("Text model warm-up: read=\(observations.count) took=\(started.duration(to: .now), privacy: .public)")
            } catch {
                logger.error("Text model warm-up failed: \(String(describing: error), privacy: .public) took=\(started.duration(to: .now), privacy: .public)")
            }
        }
    }

    /// `perform`, unless it's `.accurate` and the warm-up is still loading it.
    static func recognize(_ image: CGImage, level: RecognizeTextRequest.RecognitionLevel,
                          loading: OSAllocatedUnfairLock<Bool>, using perform: Recognizer) async throws -> [RecognizedTextObservation] {
        if level == .accurate, loading.withLock({ $0 }) { throw ModelLoading() }
        return try await perform(image, level)
    }

    /// One word, black on white: real text, so all of the read runs, not only the
    /// step that looks for text.
    static func warmUpImage() -> CGImage? {
        let width = 480, height = 160
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "START", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 40, y: 55)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
