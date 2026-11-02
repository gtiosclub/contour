//
//  LabelService.swift
//  SurfaceUnderstanding — Surface / Labels
//
//  Option O: use a server-side vision model to refine Option V's button boxes.
//
//  The source target stays independent of ContourCore changes and third-party
//  SDKs. The app supplies a base URL and headers; tests provide a fake service.
//  Failures return Option V's result unchanged so network availability never
//  removes offline detection.
//

import ContourCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

internal protocol LabelService: Sendable {
    func label(_ request: LabelRequest) async throws -> LabelReply
}

internal struct LabelRequest: Codable, Equatable, Sendable {
    internal struct Box: Codable, Equatable, Sendable {
        let id: String
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    let image: String
    let boxes: [Box]
}

internal struct LabelReply: Codable, Equatable, Sendable {
    struct Box: Codable, Equatable, Sendable {
        let id: String
        let label: String
        let isButton: Bool
    }

    let boxes: [Box]
    let start: String?
}

internal struct URLSessionLabelService: LabelService, Sendable {
    let baseURL: URL
    let headers: [String: String]
    private let session: URLSession

    init(baseURL: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.baseURL = baseURL
        self.headers = headers
        self.session = session
    }

    func label(_ request: LabelRequest) async throws -> LabelReply {
        let url = baseURL.appendingPathComponent("label")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 3
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LabelReply.self, from: data)
    }
}

internal struct OptionVResult: Sendable {
    let panel: PanelQuad
    let map: SurfaceMap

    init(panel: PanelQuad, map: SurfaceMap) {
        self.panel = panel
        self.map = map
    }
}

private enum LabelingError: Error {
    case timedOut
}

internal func applyOpenAILabels(
    to photo: PanelPhoto,
    vision: OptionVResult,
    using service: any LabelService
) async -> SurfaceMap {
    guard !vision.map.buttons.isEmpty else {
        return vision.map
    }

    do {
        let request = try labelRequest(for: photo, vision: vision)
        let reply = try await timedLabel(request, using: service)
        return try apply(reply, to: vision.map)
    } catch {
        return vision.map
    }
}

private func labelRequest(for photo: PanelPhoto, vision: OptionVResult) throws -> LabelRequest {
    let image = try photo.cgImage()
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw SurfaceUnderstandingError.underlying("Could not create JPEG destination")
    }
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw SurfaceUnderstandingError.underlying("Could not encode photo as JPEG")
    }

    return LabelRequest(
        image: data.base64EncodedString(),
        boxes: vision.map.buttons.enumerated().map { index, button in
            let bounds = photoBounds(button.bounds, within: vision.panel)
            return LabelRequest.Box(
                id: "b\(index + 1)",
                x: bounds.minX,
                y: bounds.minY,
                w: bounds.width,
                h: bounds.height
            )
        }
    )
}

private func timedLabel(
    _ request: LabelRequest,
    using service: any LabelService
) async throws -> LabelReply {
    try await withThrowingTaskGroup(of: LabelReply.self) { group in
        group.addTask {
            try await service.label(request)
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw LabelingError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func apply(_ reply: LabelReply, to map: SurfaceMap) throws -> SurfaceMap {
    let sentIDs = Set(map.buttons.indices.map { "b\($0 + 1)" })
    let replyIDs = reply.boxes.map(\.id)
    guard Set(replyIDs).count == replyIDs.count,
          replyIDs.allSatisfy(sentIDs.contains) else {
        throw LabelingError.timedOut
    }

    let replyByID = Dictionary(uniqueKeysWithValues: reply.boxes.map { ($0.id, $0) })
    if let start = reply.start {
        guard let startReply = replyByID[start], startReply.isButton else {
            throw LabelingError.timedOut
        }
    }

    let buttons = map.buttons.enumerated().compactMap { index, button -> SurfaceMap.Button? in
        let id = "b\(index + 1)"
        guard let labeled = replyByID[id] else {
            return button
        }
        guard labeled.isButton else {
            return nil
        }
        var result = button
        result.label = labeled.label
        if reply.start == id, !result.label!.localizedCaseInsensitiveContains("start") {
            result.label = "Start"
        }
        return result
    }
    return SurfaceMap(buttons: buttons, confidence: map.confidence)
}

private func photoBounds(_ bounds: PanelRect, within panel: PanelQuad) -> PanelRect {
    let detector = PanelDetector()
    func mapped(_ x: Double, _ y: Double) -> ImagePoint {
        let point = detector.rectify(ImagePoint(x: x, y: y), within: panel)
        return ImagePoint(x: point.x, y: point.y)
    }

    let inverse = PanelQuad(
        topLeft: mapped(0, 0),
        topRight: mapped(1, 0),
        bottomRight: mapped(1, 1),
        bottomLeft: mapped(0, 1)
    )
    func source(_ x: Double, _ y: Double) -> ImagePoint {
        let point = detector.rectify(ImagePoint(x: x, y: y), within: inverse)
        return ImagePoint(x: point.x, y: point.y)
    }

    let corners = [
        source(bounds.minX, bounds.minY),
        source(bounds.maxX, bounds.minY),
        source(bounds.maxX, bounds.maxY),
        source(bounds.minX, bounds.maxY)
    ]
    let minX = corners.map(\.x).min()!
    let maxX = corners.map(\.x).max()!
    let minY = corners.map(\.y).min()!
    let maxY = corners.map(\.y).max()!
    let left = min(max(minX, 0), 1)
    let top = min(max(minY, 0), 1)
    let right = min(max(maxX, 0), 1)
    let bottom = min(max(maxY, 0), 1)
    return PanelRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
}
