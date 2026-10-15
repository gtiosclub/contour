//
//  ScoreboardTests.swift
//  SurfaceUnderstandingTests — Surface / Eval & Test Set
//

import ContourCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SurfaceUnderstanding

@Test(
    "scoreboard",
    .enabled(
        if: ProcessInfo.processInfo.environment["CI"] == nil,
        "The scoreboard runs the local Vision pipeline and is intentionally skipped on CI."
    ),
    .timeLimit(.minutes(10))
)
func scoreboard() async throws {
    let samples = try TestSet.loadSamples(from: Bundle.module)
    var scored: [ScoredPhoto] = []

    for sample in samples {
        let photo = try loadPhoto(named: sample.id)
        let started = ContinuousClock.now

        do {
            let detection = try await LiveSurfaceUnderstanding().detectPanel(from: photo)
            let seconds = started.duration(to: .now).seconds
            let result = TestSet.scoreboardResult(
                photo: sample.id,
                detected: detection.map,
                detectedPanel: detection.quad,
                sample: sample,
                seconds: seconds
            )
            scored.append(ScoredPhoto(sample: sample, photo: photo, detection: detection, result: result))
        } catch {
            let seconds = started.duration(to: .now).seconds
            let result = TestSet.scoreboardResult(
                photo: sample.id,
                detected: SurfaceMap(buttons: [], confidence: 0),
                detectedPanel: nil,
                sample: sample,
                seconds: seconds
            )
            scored.append(ScoredPhoto(sample: sample, photo: photo, detection: nil, result: result))
        }
    }

    print(markdownTable(scored.map(\.result)))
    try scoreboardOverlays(scored)
}

/// Write straightened labelled-panel overlays when SCOREBOARD_OVERLAYS names a folder.
private func scoreboardOverlays(_ photos: [ScoredPhoto]) throws {
    guard let path = ProcessInfo.processInfo.environment["SCOREBOARD_OVERLAYS"],
          !path.isEmpty else {
        return
    }

    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for photo in photos {
        try writeOverlay(photo, to: directory)
    }
    print("Scoreboard overlays: \(directory.path)")
}

private struct ScoredPhoto {
    var sample: LabelledSample
    var photo: PanelPhoto
    var detection: PanelDetection?
    var result: ScoreboardResult
}

private func loadPhoto(named filename: String) throws -> PanelPhoto {
    let file = URL(fileURLWithPath: filename)
    let url = try #require(Bundle.module.url(
        forResource: file.deletingPathExtension().lastPathComponent,
        withExtension: file.pathExtension,
        subdirectory: "TestSet/photos"
    ))
    let data = try Data(contentsOf: url)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return PanelPhoto(
        data: data,
        pixelSize: PixelSize(width: image.width, height: image.height),
        orientation: .up,
        timestamp: .distantPast
    )
}

private func markdownTable(_ results: [ScoreboardResult]) -> String {
    var rows = [
        "| Photo | Center hit (R / P) | IoU ≥ 0.5 | Label right | Start | Panel | Labelled | Detected | Seconds |",
        "| --- | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: |",
    ]
    rows += results.map { result in
        "| \(result.photo) | \(result.centerHits) (\(percent(result.recall)) / \(percent(result.precision))) | \(result.iouHits) | \(result.correctLabels)/\(result.centerHits) | \(result.start) | \(result.panel.rawValue) | \(result.labelledCount) | \(result.detectedCount) | \(decimal(result.seconds)) |"
    }

    let totals = ScoreboardTotals(results)
    rows.append(
        "| **Total** | **\(totals.centerHits) (\(percent(totals.recall)) / \(percent(totals.precision)))** | **\(totals.iouHits)** | **\(totals.correctLabels)/\(totals.centerHits)** | **\(totals.startRightKey) right / \(totals.startWrongKey) wrong / \(totals.startNotFound) not found** | — | **\(totals.labelledCount)** | **\(totals.detectedCount)** | **\(decimal(totals.seconds))** |"
    )
    return rows.joined(separator: "\n")
}

private func percent(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.1f%%", value * 100)
}

private func decimal(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func writeOverlay(_ scored: ScoredPhoto, to directory: URL) throws {
    let image = try scored.photo.cgImage()
    let straightened = try straighten(image, panel: scored.sample.panel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: straightened.width,
        height: straightened.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let canvas = CGRect(x: 0, y: 0, width: straightened.width, height: straightened.height)
    context.draw(straightened, in: canvas)
    context.setLineWidth(max(2, CGFloat(straightened.width) / 350))

    context.setStrokeColor(CGColor(red: 0.12, green: 0.9, blue: 0.32, alpha: 1))
    for button in scored.sample.expected.buttons {
        context.stroke(pixelRect(button.bounds, in: straightened))
    }

    context.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.65, alpha: 1))
    if let detection = scored.detection {
        for button in detection.map.buttons {
            let mapped = TestSet.bounds(button.bounds, from: detection.quad, to: scored.sample.panel)
            context.stroke(pixelRect(mapped, in: straightened))
        }
    }

    let output = try #require(context.makeImage())
    let basename = URL(fileURLWithPath: scored.sample.id).deletingPathExtension().lastPathComponent
    let url = directory.appendingPathComponent("\(basename).png")
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, output, nil)
    #expect(CGImageDestinationFinalize(destination), "Could not write \(url.path)")
}

private func straighten(_ image: CGImage, panel: PanelQuad) throws -> CGImage {
    let input = CIImage(cgImage: image)
    let filter = try #require(CIFilter(name: "CIPerspectiveCorrection"))
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)

    func vector(_ point: ImagePoint) -> CIVector {
        CIVector(x: CGFloat(point.x) * width, y: (1 - CGFloat(point.y)) * height)
    }

    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(vector(panel.topLeft), forKey: "inputTopLeft")
    filter.setValue(vector(panel.topRight), forKey: "inputTopRight")
    filter.setValue(vector(panel.bottomRight), forKey: "inputBottomRight")
    filter.setValue(vector(panel.bottomLeft), forKey: "inputBottomLeft")
    let output = try #require(filter.outputImage)
    return try #require(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent))
}

private func pixelRect(_ bounds: PanelRect, in image: CGImage) -> CGRect {
    CGRect(
        x: bounds.minX * Double(image.width),
        y: (1 - bounds.maxY) * Double(image.height),
        width: bounds.width * Double(image.width),
        height: bounds.height * Double(image.height)
    )
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
