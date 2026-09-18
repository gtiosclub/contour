import Foundation

/// Normalized location in an upright, unmirrored image: top-left origin, y down.
/// Apply the image's orientation first. Distinct from normalized PANEL space.
public struct ImagePoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Image locations of the panel's logical corners, in perimeter order.
/// TL/TR/BR/BL correspond to panel (0,0)/(1,0)/(1,1)/(0,1).
/// Preserve these identities while tracking; never re-sort corners as it rotates.
/// Detection must supply a nondegenerate, non-self-intersecting quadrilateral.
public struct PanelQuad: Hashable, Sendable, Codable {
    public var topLeft: ImagePoint
    public var topRight: ImagePoint
    public var bottomRight: ImagePoint
    public var bottomLeft: ImagePoint

    public init(topLeft: ImagePoint, topRight: ImagePoint,
                bottomRight: ImagePoint, bottomLeft: ImagePoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Only for fixtures or images known to be cropped exactly to the panel.
    public static let fullFrame = PanelQuad(
        topLeft: ImagePoint(x: 0, y: 0), topRight: ImagePoint(x: 1, y: 0),
        bottomRight: ImagePoint(x: 1, y: 1), bottomLeft: ImagePoint(x: 0, y: 1))
}

/// Surface Understanding's complete result. Button bounds MUST be normalized
/// against this exact quad in the upright reference image, not a second crop.
public struct PanelDetection: Hashable, Sendable, Codable {
    public let referencePhotoID: UUID
    public let quad: PanelQuad
    public let map: SurfaceMap

    public init(referencePhotoID: UUID, quad: PanelQuad, map: SurfaceMap) {
        self.referencePhotoID = referencePhotoID
        self.quad = quad
        self.map = map
    }
}

/// App-assembled initialization for Tracking. Retains the actual reference pixels
/// and orientation; a layout alone is insufficient to locate the panel again.
public struct PanelReference: Hashable, Sendable, Codable {
    public enum ReferenceError: Error, Equatable { case photoMismatch }
    public let photo: PanelPhoto
    public let detection: PanelDetection

    public init(photo: PanelPhoto, detection: PanelDetection) throws {
        guard photo.id == detection.referencePhotoID else { throw ReferenceError.photoMismatch }
        self.photo = photo
        self.detection = detection
    }

    private enum CodingKeys: String, CodingKey { case photo, detection }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(photo: container.decode(PanelPhoto.self, forKey: .photo),
                      detection: container.decode(PanelDetection.self, forKey: .detection))
    }
}
