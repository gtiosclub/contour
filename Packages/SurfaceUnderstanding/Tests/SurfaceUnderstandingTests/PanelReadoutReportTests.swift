//
//  PanelReadoutReportTests.swift
//  SurfaceUnderstandingTests — Surface / Eval & Test Set
//

import ContourCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SurfaceUnderstanding

@Test(
    "panel readout report",
    .enabled(
        if: ProcessInfo.processInfo.environment["CI"] == nil,
        "The report runs the local Vision pipeline and is intentionally skipped on CI."
    ),
    .timeLimit(.minutes(30))
)
func panelReadoutReport() async throws {
    var inputs = try bundledReportPhotos()
    if let frames = ProcessInfo.processInfo.environment["PANEL_READOUT_FRAMES"], !frames.isEmpty {
        inputs += try imageReportPhotos(in: URL(fileURLWithPath: frames, isDirectory: true), source: "720x1280")
    }
    if let scans = ProcessInfo.processInfo.environment["SCANS"], !scans.isEmpty {
        inputs += try recordedScanPhotos(in: URL(fileURLWithPath: scans, isDirectory: true))
    }

    var rows = [
        "| Source | Photo | Quad | Display | Display seconds | Button words |",
        "| --- | --- | --- | --- | ---: | ---: |",
    ]
    var details: [String] = []
    let readout = PanelReadout()

    for input in inputs {
        do {
            let detection = try await LiveSurfaceUnderstanding().detectPanel(from: input.photo)
            let started = ContinuousClock.now
            let display = await readout.readDisplay(in: input.photo, panel: detection.quad)
            let seconds = started.duration(to: .now).reportSeconds
            let buttons = readout.buttonList(for: detection.map)
            let wordCount = buttons.split(whereSeparator: \.isWhitespace).count
            rows.append(
                "| \(input.source) | \(input.name) | \(detection.quad == .fullFrame ? "full frame" : "detected") | \(display.spoken) | \(String(format: "%.3f", seconds)) | \(wordCount) |"
            )
            details.append("### \(input.source): \(input.name)\n\n\(buttons)")
        } catch {
            rows.append("| \(input.source) | \(input.name) | error | \(String(describing: error)) | — | — |")
        }
    }

    print(rows.joined(separator: "\n"))
    print("\n<details><summary>Full button lists</summary>\n\n\(details.joined(separator: "\n\n"))\n\n</details>")
}

private struct ReportPhoto {
    var source: String
    var name: String
    var photo: PanelPhoto
}

private struct RecordedReadoutScan: Decodable {
    var pixelSize: PixelSize
    var orientation: PhotoOrientation
    var detection: PanelDetection?
}

private func bundledReportPhotos() throws -> [ReportPhoto] {
    let directory = try #require(Bundle.module.url(
        forResource: "photos",
        withExtension: nil,
        subdirectory: "TestSet"
    ))
    return try imageReportPhotos(in: directory, source: "full size")
}

private func imageReportPhotos(in directory: URL, source: String) throws -> [ReportPhoto] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { ["jpg", "jpeg", "heic", "heif"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { url in
            ReportPhoto(source: source, name: url.lastPathComponent, photo: try reportPhoto(at: url))
        }
}

private func reportPhoto(at url: URL) throws -> PanelPhoto {
    let data = try Data(contentsOf: url)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let orientation: PhotoOrientation = switch rawOrientation {
    case 3: .down
    case 6: .right
    case 8: .left
    default: .up
    }
    return PanelPhoto(
        data: data,
        pixelSize: PixelSize(width: image.width, height: image.height),
        orientation: orientation,
        timestamp: .distantPast
    )
}

/// Loads scan-recorder JSON and preserves the camera orientation stored beside each JPEG.
private func recordedScanPhotos(in directory: URL) throws -> [ReportPhoto] {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return try files
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { metadataURL in
            let recorded = try JSONDecoder().decode(
                RecordedReadoutScan.self,
                from: Data(contentsOf: metadataURL)
            )
            let name = metadataURL.deletingPathExtension().lastPathComponent
            let imageURL = directory.appendingPathComponent(name).appendingPathExtension("jpg")
            let photo = PanelPhoto(
                id: recorded.detection?.referencePhotoID ?? UUID(),
                data: try Data(contentsOf: imageURL),
                pixelSize: recorded.pixelSize,
                orientation: recorded.orientation,
                timestamp: .distantPast
            )
            return ReportPhoto(source: "scan", name: name, photo: photo)
        }
}

private extension Duration {
    var reportSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
