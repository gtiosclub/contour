//
//  ScanReplayTests.swift
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

private let scansPath = ProcessInfo.processInfo.environment["SCANS"]

@Test(
    "replay recorded scans",
    .enabled(
        if: scansPath != nil,
        "Set SCANS to a downloaded AppData/Documents/scans folder."
    ),
    .timeLimit(.minutes(30))
)
func scanReplay() async throws {
    guard let scansPath else { return }

    let directory = URL(fileURLWithPath: scansPath, isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    let metadataFiles = files
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let overlays = directory.appendingPathComponent("replay-overlays", isDirectory: true)
    try FileManager.default.createDirectory(at: overlays, withIntermediateDirectories: true)

    print("| scan | distance, angle, display, lights | phone s | panel, Start, right? |")
    print("| --- | --- | ---: | --- |")
    var rows: [(recorded: RecordedScan, result: ReplayResult)] = []

    for metadataURL in metadataFiles {
        let recorded = try JSONDecoder().decode(
            RecordedScan.self,
            from: Data(contentsOf: metadataURL)
        )
        let basename = metadataURL.deletingPathExtension().lastPathComponent
        let imageURL = directory.appendingPathComponent(basename).appendingPathExtension("jpg")
        let photo = PanelPhoto(
            id: recorded.detection?.referencePhotoID ?? UUID(),
            data: try Data(contentsOf: imageURL),
            pixelSize: recorded.pixelSize,
            orientation: recorded.orientation,
            timestamp: .distantPast
        )

        let result: ReplayResult
        do {
            let detection = try await LiveSurfaceUnderstanding().detectPanel(from: photo)
            let match = TargetMatcher().match("start", in: detection.map)
            let appStart = appStartButton(in: detection.map)
            result = ReplayResult(detection: detection, match: match, appStart: appStart, error: nil)
        } catch {
            result = ReplayResult(
                detection: nil,
                match: nil,
                appStart: nil,
                error: String(reflecting: error)
            )
        }

        try writeOverlay(
            photo: photo,
            detection: result.detection ?? recorded.detection,
            match: result.match,
            named: basename,
            to: overlays
        )

        let cold = recorded.firstScan ? "cold" : "warm"
        print(
            "| \(basename) | _fill in_ | \(decimal(recorded.seconds)) (\(cold)) | \(summary(result)); right? _ |"
        )
        rows.append((recorded, result))
    }

    print("| **Total** | — | **\(timingSummary(rows.map(\.recorded)))** | **\(guideableCount(rows.map(\.result)))/\(rows.count) quad + on-panel Start candidates; confirm right key from PNGs** |")
    print("Replay overlays: \(overlays.path)")
}

private struct RecordedScan: Decodable {
    let pixelSize: PixelSize
    let orientation: PhotoOrientation
    let detection: PanelDetection?
    let seconds: Double
    let firstScan: Bool
    let error: String?
}

private struct ReplayResult {
    let detection: PanelDetection?
    let match: TargetMatch?
    let appStart: SurfaceMap.Button?
    let error: String?
}

private func summary(_ result: ReplayResult) -> String {
    guard let detection = result.detection else {
        return "error: \(result.error ?? "unknown")"
    }

    let panel = detection.quad == .fullFrame ? "fullFrame" : "quad"
    var start = describe(result.match?.button)
    if result.match?.button.id != result.appStart?.id {
        start += "; app Start: \(describe(result.appStart))"
    }
    return "\(panel), Start: \(start)"
}

private func describe(_ button: SurfaceMap.Button?) -> String {
    guard let button else { return "not found" }
    guard isOnPanel(button) else { return "off panel" }
    return button.label ?? "unlabelled"
}

private func isOnPanel(_ button: SurfaceMap.Button) -> Bool {
    let center = button.bounds.center
    return (0...1).contains(center.x) && (0...1).contains(center.y)
}

private func guideableCount(_ results: [ReplayResult]) -> Int {
    results.count { result in
        guard let detection = result.detection,
              detection.quad != .fullFrame,
              let button = result.match?.button else {
            return false
        }
        return isOnPanel(button)
    }
}

private func timingSummary(_ scans: [RecordedScan]) -> String {
    let cold = timing(scans.filter(\.firstScan).map(\.seconds))
    let warm = timing(scans.filter { !$0.firstScan }.map(\.seconds))
    return "cold median/slowest \(cold); warm median/slowest \(warm)"
}

private func timing(_ values: [Double]) -> String {
    let sorted = values.sorted()
    guard let slowest = sorted.last else { return "n/a" }
    let middle = sorted.count / 2
    let median = sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
    return "\(decimal(median))/\(decimal(slowest)) s"
}

/// Mirrors the app's current Start fallback without importing the app target.
private func appStartButton(in map: SurfaceMap) -> SurfaceMap.Button? {
    let labelled = map.buttons.compactMap { button in
        button.label.map { (button, $0) }
    }
    if let exact = labelled.first(where: { _, label in
        label.split(separator: "/").contains {
            $0.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare("Start") == .orderedSame
        }
    }) {
        return exact.0
    }

    return labelled
        .filter { words($0.1).contains("start") }
        .min { words($0.1).count < words($1.1).count }?.0
}

private func words(_ label: String) -> [String] {
    label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

private func writeOverlay(
    photo: PanelPhoto,
    detection: PanelDetection?,
    match: TargetMatch?,
    named basename: String,
    to directory: URL
) throws {
    let image = try photo.cgImage()
    let panelImage = try detection.map { try straighten(image, panel: $0.quad) } ?? image
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: panelImage.width,
        height: panelImage.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let canvas = CGRect(x: 0, y: 0, width: panelImage.width, height: panelImage.height)
    context.draw(panelImage, in: canvas)

    if let button = match?.button, isOnPanel(button) {
        context.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.15, alpha: 1))
        context.setLineWidth(max(4, CGFloat(panelImage.width) / 175))
        context.stroke(pixelRect(button.bounds, in: panelImage))
    }

    let output = try #require(context.makeImage())
    let url = directory.appendingPathComponent(basename).appendingPathExtension("png")
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
    return try #require(
        CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    )
}

private func pixelRect(_ bounds: PanelRect, in image: CGImage) -> CGRect {
    CGRect(
        x: bounds.minX * Double(image.width),
        y: (1 - bounds.maxY) * Double(image.height),
        width: bounds.width * Double(image.width),
        height: bounds.height * Double(image.height)
    )
}

private func decimal(_ value: Double) -> String {
    String(format: "%.3f", value)
}
