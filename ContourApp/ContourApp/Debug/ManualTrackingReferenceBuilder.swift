#if DEBUG
import ContourCore
import Foundation
import Tracking

/// Test-only reference from a real captured frame and a manually chosen target.
/// Does not invent a microwave layout or call Surface Understanding.
enum ManualTrackingReferenceBuilder {
    enum BuildError: LocalizedError, Equatable {
        case invalidPanel, targetOutsidePanel
        var errorDescription: String? {
            switch self {
            case .invalidPanel: "Mark the actual panel corners in top-left, top-right, bottom-right, bottom-left order."
            case .targetOutsidePanel: "Tap a target button center strictly inside the marked panel."
            }
        }
    }
    static func make(photo: PanelPhoto, corners: [ImagePoint], target: ImagePoint) throws -> PanelReference {
        guard corners.count == 4 else { throw BuildError.invalidPanel }
        let quad = PanelQuad(topLeft: corners[0], topRight: corners[1],
                             bottomRight: corners[2], bottomLeft: corners[3])
        guard quad != .fullFrame, let geometry = try? PanelHomography(quad: quad) else {
            throw BuildError.invalidPanel
        }
        guard let point = geometry.panelPoint(for: target),
              point.x > 0, point.x < 1, point.y > 0, point.y < 1 else {
            throw BuildError.targetOutsidePanel
        }
        // This is an approximate target around the manually tapped center,
        // not a detected button outline. Preserve the marked center at edges.
        let halfWidth = min(0.03, point.x, 1 - point.x)
        let halfHeight = min(0.03, point.y, 1 - point.y)
        let button = SurfaceMap.Button(label: "Manual target",
            bounds: PanelRect(x: point.x - halfWidth, y: point.y - halfHeight,
                              width: 2 * halfWidth, height: 2 * halfHeight), confidence: 1)
        return try ManualPanelReferenceBuilder.make(photo: photo, corners: corners,
            layout: SurfaceMap(buttons: [button], confidence: 1))
    }
}
#endif
