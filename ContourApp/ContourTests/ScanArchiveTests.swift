//
//  ScanArchiveTests.swift
//  ContourTests
//
//  The debug recorder that keeps every scan for measuring on the Mac.
//

import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import Testing
@testable import ContourApp

@Suite("Scan archive")
struct ScanArchiveTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "ScanArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var archive: ScanArchive { ScanArchive(directory: folder) }

    private func photo(_ bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]) -> PanelPhoto {
        PanelPhoto(data: Data(bytes), pixelSize: PixelSize(width: 1440, height: 1920),
                   timestamp: Date(timeIntervalSince1970: 1_795_000_000))
    }

    /// A panel filling the middle of the photo, with a 1 key and a Start key.
    private func detection(for photo: PanelPhoto) -> PanelDetection {
        let quad = PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.2), topRight: ImagePoint(x: 0.9, y: 0.2),
                             bottomRight: ImagePoint(x: 0.9, y: 0.8), bottomLeft: ImagePoint(x: 0.1, y: 0.8))
        let map = SurfaceMap(buttons: [
            SurfaceMap.Button(label: "1", bounds: PanelRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5), confidence: 0.9),
            SurfaceMap.Button(label: "Start", bounds: PanelRect(x: 0, y: 0, width: 0.2, height: 0.1), confidence: 1),
        ], confidence: 0.8)
        return PanelDetection(referencePhotoID: photo.id, quad: quad, map: map)
    }

    private func json(_ sidecar: ScanArchive.Sidecar) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: ScanArchive.encode(sidecar)) as? [String: Any])
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path()).sorted()
    }

    @Test("The sidecar has what the real-frames scoreboard reads, and the detection round-trips")
    func scoreboardReadsTheSidecar() throws {
        let photo = photo()
        let detection = detection(for: photo)
        let sidecar = ScanArchive.Sidecar(photo: photo, detection: detection, error: nil, seconds: 0.8,
                                          firstScan: true, canGuide: true)
        let meta = try json(sidecar)

        // Read exactly as recordedPhoto(_:) in KeypadReaderTests does.
        let size = try #require(meta["pixelSize"] as? [String: Int])
        #expect(size["width"] == 1440 && size["height"] == 1920)
        #expect(PhotoOrientation(rawValue: meta["orientation"] as? String ?? "") == .up)

        // The replay on PR #143 decodes the detection itself.
        let data = try JSONSerialization.data(withJSONObject: try #require(meta["detection"]))
        #expect(try JSONDecoder().decode(PanelDetection.self, from: data) == detection)
        #expect(meta["seconds"] as? Double == 0.8)
        #expect(meta["firstScan"] as? Bool == true)
        #expect(meta["error"] == nil)
    }

    @Test("The sidecar says what the app made of the scan, with each box in the photo")
    func sidecarHasWhatTheAppSaw() throws {
        let photo = photo()
        let sidecar = ScanArchive.Sidecar(photo: photo, detection: detection(for: photo), error: nil,
                                          seconds: 0.8, firstScan: false, canGuide: true)
        let meta = try json(sidecar)

        #expect(meta["fullFrame"] as? Bool == false)
        #expect(meta["keypadFound"] as? Bool == true)
        #expect(meta["canGuide"] as? Bool == true)
        #expect(meta["capturedAt"] as? String == "2026-11-18T11:06:40Z")
        #expect(sidecar.buttons.map(\.label) == ["1", "Start"])
        // Panel (0.5, 0.5)...(0.75, 1) lands at photo (0.5, 0.5)...(0.7, 0.8) inside that quad.
        let corners = try #require(sidecar.buttons.first?.corners)
        let expected = [(0.5, 0.5), (0.7, 0.5), (0.7, 0.8), (0.5, 0.8)]
        #expect(corners.count == 4)
        for (corner, (x, y)) in zip(corners, expected) {
            #expect(abs(corner.x - x) < 1e-9 && abs(corner.y - y) < 1e-9)
        }
    }

    @Test("A scan that threw keeps the reason and claims nothing was found")
    func failedScan() throws {
        let sidecar = ScanArchive.Sidecar(photo: photo(), detection: nil, error: SurfaceUnderstandingError.noPanelFound,
                                          seconds: 0.3, firstScan: false, canGuide: false)
        let meta = try json(sidecar)

        #expect(meta["error"] as? String == "noPanelFound")
        #expect(meta["detection"] == nil)
        #expect(meta["fullFrame"] == nil)
        #expect(meta["keypadFound"] as? Bool == false)
        #expect(meta["canGuide"] as? Bool == false)
        #expect((meta["buttons"] as? [Any])?.isEmpty == true)
        #expect(meta["pixelSize"] as? [String: Int] == ["width": 1440, "height": 1920])
    }

    @Test("Saving writes NAME.jpg with the photo's bytes unchanged and NAME.json beside it")
    func savesPhotoAndSidecar() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = photo([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        let sidecar = ScanArchive.Sidecar(photo: photo, detection: detection(for: photo), error: nil,
                                          seconds: 1, firstScan: true, canGuide: true)

        #expect(try archive.write(sidecar, photo: photo.data, named: "scan"))

        #expect(try files() == ["scan.jpg", "scan.json"])
        #expect(try Data(contentsOf: folder.appending(path: "scan.jpg")) == photo.data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(ScanArchive.Sidecar.self, from: Data(contentsOf: folder.appending(path: "scan.json")))
        #expect(saved == sidecar)
    }

    @Test("Only the newest scans are kept, photo and sidecar together")
    func keepsTheNewest() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var archive = archive
        archive.limit = 3
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let names = (1...5).map { ScanArchive.name(for: start.addingTimeInterval(Double($0) * 61), number: $0) }
        let sidecar = ScanArchive.Sidecar(photo: photo(), detection: nil, error: nil, seconds: 0,
                                          firstScan: false, canGuide: false)

        // Saved out of order, so it's the names that decide which are oldest.
        for name in names.reversed() {
            try archive.write(sidecar, photo: photo().data, named: name)
        }

        #expect(try files() == names.suffix(3).flatMap { ["\($0).jpg", "\($0).json"] })
        #expect(archive.count() == 3)
    }

    @Test("Names sort oldest first and need no escaping")
    func nameOrder() {
        let earlier = ScanArchive.name(for: Date(timeIntervalSince1970: 1_795_000_000), number: 12)
        let later = ScanArchive.name(for: Date(timeIntervalSince1970: 1_795_000_000.5), number: 1)

        #expect(earlier < later)
        // In UTC, whatever the phone's time zone, and the shape Scripts/pull-scans.sh looks for.
        #expect(earlier == "2026-11-18-110640-000-0012")
    }

    @Test("Nothing is saved when the phone is low on space")
    func lowOnSpace() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var archive = archive
        archive.minimumFreeBytes = .max
        let sidecar = ScanArchive.Sidecar(photo: photo(), detection: nil, error: nil, seconds: 0,
                                          firstScan: false, canGuide: false)

        #expect(try !archive.write(sidecar, photo: photo().data, named: "scan"))
        #expect(try files().isEmpty)
    }

    @Test("Clearing deletes every saved scan")
    func clears() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidecar = ScanArchive.Sidecar(photo: photo(), detection: nil, error: nil, seconds: 0,
                                          firstScan: false, canGuide: false)
        try archive.write(sidecar, photo: photo().data, named: "a")
        try archive.write(sidecar, photo: photo().data, named: "b")
        #expect(archive.count() == 2)

        archive.clear()
        ScanArchive.queue.sync {}

        #expect(archive.count() == 0)
    }

    @MainActor
    @Test("Every scan is saved, one that threw too, and the result is passed on")
    func savesEveryAttempt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        func pipeline(_ surface: MockSurfaceUnderstanding) -> ContourPipeline {
            ContourPipeline(surfaceUnderstanding: surface, tracking: MockTrackingSource(),
                            feedback: PrintingFeedbackEngine(isPrinting: false), liveComponents: [])
        }

        let map = try await archive.detectPanel(in: photo(), with: pipeline(MockSurfaceUnderstanding()))
        await #expect(throws: SurfaceUnderstandingError.noPanelFound) {
            try await archive.detectPanel(in: photo(), with: pipeline(MockSurfaceUnderstanding(failure: .noPanelFound)))
        }
        // A photo with no pixels, as without a camera, isn't kept.
        _ = try await archive.detectPanel(in: PanelPhoto(data: Data(), pixelSize: PixelSize(width: 1, height: 1),
                                                         timestamp: Date()), with: pipeline(MockSurfaceUnderstanding()))
        ScanArchive.queue.sync {}

        #expect(map == MockSurfaceMaps.microwave)
        let sidecars = try files().filter { $0.hasSuffix(".json") }.map {
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: $0))) as? [String: Any]
        }
        #expect(sidecars.count == 2)
        #expect(sidecars.contains { $0?["error"] == nil && $0?["canGuide"] as? Bool == true && $0?["detection"] != nil })
        #expect(sidecars.contains { $0?["error"] as? String == "noPanelFound" && $0?["detection"] == nil })
    }
}
