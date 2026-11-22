#if DEBUG
import ContourCore
import Foundation
import os
import SurfaceUnderstanding
import Tracking

/// Every scan's photo and what came of it, kept in Documents/Scans so a phone
/// run can be measured again on the Mac. Scripts/pull-scans.sh copies them off.
///
/// NAME.jpg is the exact photo the scanner read, already upright. NAME.json has
/// what the real-frames scoreboard (KeypadReaderTests) reads, so the pulled
/// folder works as its CONTOUR_FRAMES_DIR, then what the app made of the scan.
nonisolated struct ScanArchive: Sendable {
    static let shared = ScanArchive(directory: .documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory))
    /// Saving happens here, one scan at a time, off the main thread.
    static let queue = DispatchQueue(label: "edu.gatech.contour.scan-archive", qos: .utility)
    private static let logger = Logger(subsystem: "edu.gatech.contour", category: "ScanArchive")
    @MainActor private static var scans = 0

    let directory: URL
    /// The newest scans kept. A photo is 1 to 2 MB, so this stays under about 600 MB.
    var limit = 300
    /// Nothing more is saved once the phone has less free space than this.
    var minimumFreeBytes: Int64 = 500_000_000

    /// What NAME.json holds.
    nonisolated struct Sidecar: Codable, Equatable, Sendable {
        // Read by the real-frames scoreboard and by the replay test on PR #143.
        var pixelSize: PixelSize
        var orientation: PhotoOrientation
        /// `nil` when the scan threw, with the reason in `error`.
        var detection: PanelDetection?
        /// From handing over the photo to a panel ready to guide, or to the error.
        /// Unlike PR #143's, this includes getting tracking ready on the panel.
        var seconds: Double
        /// The first scan since the app opened.
        var firstScan: Bool
        var error: String?

        // What the app made of it.
        var capturedAt: Date
        /// `nil` when nothing was found.
        var fullFrame: Bool?
        /// Any digit key, the same check as the "Number keys not found" warning.
        var keypadFound: Bool
        /// False when the app wouldn't guide, as after a full-frame scan.
        var canGuide: Bool
        var buttons: [Button]

        nonisolated struct Button: Codable, Equatable, Sendable {
            var label: String?
            var confidence: Double
            /// On the panel, against `detection.quad`, like `SurfaceMap.Button.bounds`.
            var bounds: PanelRect
            /// The same box in the photo: top left, top right, bottom right, bottom
            /// left, each 0...1 of the photo's width and height, y down. Empty if
            /// the quad can't be mapped.
            var corners: [ImagePoint]
        }
    }

    /// `pipeline.detectPanel(in:)`. Then the photo and what came of it are
    /// saved in the background, whether the scan worked or threw.
    @MainActor func detectPanel(in photo: PanelPhoto, with pipeline: ContourPipeline) async throws -> SurfaceMap {
        // Without a camera the photo is empty, as in tests: nothing to keep.
        guard !photo.data.isEmpty else { return try await pipeline.detectPanel(in: photo) }
        Self.scans += 1
        let number = Self.scans
        let started = ContinuousClock.now
        func keep(_ error: (any Error)?) {
            // Also there when a scan was cancelled after detection.
            let reference = pipeline.panelReference.flatMap { $0.photo.id == photo.id ? $0 : nil }
            let sidecar = Sidecar(photo: photo, detection: reference?.detection, error: error,
                                  seconds: started.duration(to: .now) / .seconds(1), firstScan: number == 1,
                                  canGuide: reference != nil && pipeline.canGuide)
            save(sidecar, photo: photo.data, named: Self.name(for: photo.timestamp, number: number))
        }
        do {
            let map = try await pipeline.detectPanel(in: photo)
            keep(nil)
            return map
        } catch {
            keep(error)
            throw error
        }
    }

    /// The capture time in UTC first, so names sort oldest first, then the
    /// scan's number since the app opened. Scripts/pull-scans.sh looks for
    /// names of this shape.
    static func name(for date: Date, number: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter.string(from: date) + String(format: "-%04ld", number)
    }

    static func encode(_ sidecar: Sidecar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sidecar)
    }

    private func save(_ sidecar: Sidecar, photo: Data, named name: String) {
        Self.queue.async {
            do {
                if try !write(sidecar, photo: photo, named: name) {
                    Self.logger.notice("Scan \(name, privacy: .public) not saved: the phone is low on space")
                }
            } catch {
                Self.logger.error("Scan \(name, privacy: .public) not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Saves one scan, then drops the oldest past `limit`. False when there
    /// wasn't room for it.
    @discardableResult
    func write(_ sidecar: Sidecar, photo: Data, named name: String) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Hundreds of megabytes of debug photos shouldn't fill an iCloud backup.
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        guard freeBytes() >= minimumFreeBytes else { return false }
        // The scoreboard lists photos and then needs each one's sidecar, so the
        // sidecar goes first: a scan cut off in between is skipped, not an error.
        try Self.encode(sidecar).write(to: file(name, "json"), options: .atomic)
        try photo.write(to: file(name, "jpg"), options: .atomic)
        try prune()
        return true
    }

    /// Drops the oldest scans past `limit`.
    func prune() throws {
        for name in try names().dropLast(limit) {
            try? FileManager.default.removeItem(at: file(name, "jpg"))
            try? FileManager.default.removeItem(at: file(name, "json"))
        }
    }

    /// How many scans are saved.
    func count() -> Int { (try? names().count) ?? 0 }

    /// Deletes every saved scan, after any still being saved.
    func clear() {
        Self.queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Each saved scan's NAME, oldest first.
    private func names() throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return Set(files.filter { ["jpg", "json"].contains($0.pathExtension) }
            .map { $0.deletingPathExtension().lastPathComponent }).sorted()
    }

    private func file(_ name: String, _ type: String) -> URL {
        directory.appending(path: name).appendingPathExtension(type)
    }

    /// Unknown counts as plenty: `limit` still caps what's kept.
    private func freeBytes() -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}

nonisolated extension ScanArchive.Sidecar {
    init(photo: PanelPhoto, detection: PanelDetection?, error: (any Error)?, seconds: Double,
         firstScan: Bool, canGuide: Bool) {
        let homography = detection.flatMap { try? PanelHomography(quad: $0.quad) }
        let buttons = detection?.map.buttons.map { button in
            let box = button.bounds
            let corners = [PanelPoint(x: box.minX, y: box.minY), PanelPoint(x: box.maxX, y: box.minY),
                           PanelPoint(x: box.maxX, y: box.maxY), PanelPoint(x: box.minX, y: box.maxY)]
                .compactMap { homography?.imagePoint(for: $0) }
            return Button(label: button.label, confidence: button.confidence, bounds: box,
                          corners: corners.count == 4 ? corners : [])
        }
        self.init(pixelSize: photo.pixelSize, orientation: photo.orientation, detection: detection,
                  seconds: seconds, firstScan: firstScan, error: error.map { String(describing: $0) },
                  capturedAt: photo.timestamp, fullFrame: detection.map { $0.quad == .fullFrame },
                  keypadFound: detection?.map.hasNumberKeys ?? false, canGuide: canGuide,
                  buttons: buttons ?? [])
    }
}
#endif
