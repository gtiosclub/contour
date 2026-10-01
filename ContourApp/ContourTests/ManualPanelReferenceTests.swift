import ContourCore
import ContourMocks
import Foundation
import Testing
import UIKit
@testable import ContourApp

@Suite("Manual reference setup")
struct ManualPanelReferenceTests {
    private func photo() -> PanelPhoto {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            }
        return PanelPhoto(data: image.jpegData(compressionQuality: 1)!,
                          pixelSize: PixelSize(width: 32, height: 24), timestamp: Date())
    }

    @Test("marked fixture corners and its supplied layout produce a matching reference")
    func producesReference() throws {
        let photo = photo()
        let corners = [ImagePoint(x: 0.1, y: 0.1), ImagePoint(x: 0.9, y: 0.1),
                       ImagePoint(x: 0.9, y: 0.9), ImagePoint(x: 0.1, y: 0.9)]
        let reference = try ManualPanelReferenceBuilder.make(
            photo: photo, corners: corners, layout: MockSurfaceMaps.microwave)
        #expect(reference.photo.id == reference.detection.referencePhotoID)
        #expect(reference.detection.quad.topLeft == corners[0])
        #expect(reference.detection.map.button(labelled: "Start") != nil)
    }

    @Test("crossed corners are rejected before starting tracking")
    func rejectsCrossedCorners() {
        let corners = [ImagePoint(x: 0.1, y: 0.1), ImagePoint(x: 0.9, y: 0.9),
                       ImagePoint(x: 0.9, y: 0.1), ImagePoint(x: 0.1, y: 0.9)]
        #expect(throws: ManualPanelReferenceBuilder.BuildError.invalidCorners) {
            try ManualPanelReferenceBuilder.make(
                photo: photo(), corners: corners, layout: MockSurfaceMaps.microwave)
        }
    }
}
