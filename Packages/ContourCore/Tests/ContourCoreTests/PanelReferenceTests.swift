import Foundation
import Testing
@testable import ContourCore

@Test("A reference rejects geometry from a different photo")
func mismatchedReference() throws {
    let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 100, height: 100), timestamp: Date())
    let detection = PanelDetection(referencePhotoID: UUID(), quad: .fullFrame, map: .empty)
    #expect(throws: PanelReference.ReferenceError.photoMismatch) {
        try PanelReference(photo: photo, detection: detection)
    }
}

@Test("Reference preserves orientation, ordered image corners and panel map through serialization")
func referenceRoundTrip() throws {
    let photo = PanelPhoto(data: Data([1, 2]), pixelSize: PixelSize(width: 200, height: 100),
                           orientation: .right, timestamp: Date(timeIntervalSince1970: 10))
    let quad = PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.2), topRight: ImagePoint(x: 0.8, y: 0.1),
                         bottomRight: ImagePoint(x: 0.9, y: 0.9), bottomLeft: ImagePoint(x: 0.2, y: 0.8))
    let reference = try PanelReference(photo: photo, detection: PanelDetection(
        referencePhotoID: photo.id, quad: quad, map: .empty))
    let decoded = try JSONDecoder().decode(PanelReference.self, from: JSONEncoder().encode(reference))
    #expect(decoded == reference)
    #expect(decoded.detection.quad.topLeft == quad.topLeft)
}

@Test("Decoding cannot bypass reference identity validation")
func decodingMismatchedReference() throws {
    let photo = PanelPhoto(data: Data(), pixelSize: PixelSize(width: 1, height: 1), timestamp: Date())
    let reference = try PanelReference(photo: photo, detection: PanelDetection(
        referencePhotoID: photo.id, quad: .fullFrame, map: .empty))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
    var detection = try #require(object["detection"] as? [String: Any])
    detection["referencePhotoID"] = UUID().uuidString
    object["detection"] = detection
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: PanelReference.ReferenceError.photoMismatch) {
        try JSONDecoder().decode(PanelReference.self, from: data)
    }
}
