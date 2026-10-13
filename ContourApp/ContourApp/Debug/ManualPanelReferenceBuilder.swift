#if DEBUG
import ContourCore
import Foundation

/// Builds a reference from an upright captured image and manually marked
/// corners. The caller must supply a layout for the *same* marked panel.
enum ManualPanelReferenceBuilder {
    enum BuildError: LocalizedError, Equatable {
        case invalidPhoto, invalidCorners, invalidLayout

        var errorDescription: String? {
            switch self {
            case .invalidPhoto: "The captured image is empty or has invalid dimensions."
            case .invalidCorners: "Mark four distinct corners in top-left, top-right, bottom-right, bottom-left order."
            case .invalidLayout: "The supplied layout has invalid button bounds."
            }
        }
    }

    static func make(photo: PanelPhoto, corners: [ImagePoint], layout: SurfaceMap) throws -> PanelReference {
        guard !photo.data.isEmpty, photo.pixelSize.width > 0, photo.pixelSize.height > 0,
              photo.orientation == .up else { throw BuildError.invalidPhoto }
        guard corners.count == 4,
              corners.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw BuildError.invalidCorners
        }
        let turns = corners.indices.map { i -> Double in
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 0.0001 }) || turns.allSatisfy({ $0 < -0.0001 }) else {
            throw BuildError.invalidCorners
        }
        guard (0...1).contains(layout.confidence),
              layout.buttons.allSatisfy({ button in
                  let b = button.bounds
                  return (0...1).contains(button.confidence) && b.width > 0 && b.height > 0
                      && b.minX >= 0 && b.minY >= 0 && b.maxX <= 1 && b.maxY <= 1
              }) else { throw BuildError.invalidLayout }
        let quad = PanelQuad(topLeft: corners[0], topRight: corners[1],
                             bottomRight: corners[2], bottomLeft: corners[3])
        let detection = PanelDetection(referencePhotoID: photo.id, quad: quad, map: layout)
        return try PanelReference(photo: photo, detection: detection)
    }
}
#endif
