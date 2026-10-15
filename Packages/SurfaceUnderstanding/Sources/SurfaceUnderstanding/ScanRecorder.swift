#if DEBUG && os(iOS)

import ContourCore
import Foundation

/// Persists the exact frames and results used by on-device surface scans.
actor ScanRecorder {
    static let shared = ScanRecorder()

    private var scanCount = 0
    private let timestampFormatter: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
    }

    func record(
        photo: PanelPhoto,
        detection: PanelDetection?,
        seconds: Double,
        error: String?
    ) throws {
        let firstScan = scanCount == 0
        scanCount += 1

        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw ScanRecorderError.documentsDirectoryUnavailable
        }

        let directory = documents.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let timestamp = timestampFormatter.string(from: Date())
        let basename = String(format: "%@-%04d", timestamp, scanCount)
        let imageURL = directory.appendingPathComponent(basename).appendingPathExtension("jpg")
        let metadataURL = directory.appendingPathComponent(basename).appendingPathExtension("json")
        let metadata = RecordedScan(
            pixelSize: photo.pixelSize,
            orientation: photo.orientation,
            detection: detection,
            seconds: seconds,
            firstScan: firstScan,
            error: error
        )

        try photo.data.write(to: imageURL, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }
}

private struct RecordedScan: Encodable {
    let pixelSize: PixelSize
    let orientation: PhotoOrientation
    let detection: PanelDetection?
    let seconds: Double
    let firstScan: Bool
    let error: String?
}

private enum ScanRecorderError: Error {
    case documentsDirectoryUnavailable
}

#endif
