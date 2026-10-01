import ContourCore
import ContourMocks
import Foundation
import Testing
import Tracking
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

    @Test("replacement clears the old target and rejects IDs outside the new layout")
    func replacementScopesTargetToNewLayout() throws {
        let corners = [ImagePoint(x: 0.1, y: 0.1), ImagePoint(x: 0.9, y: 0.1),
                       ImagePoint(x: 0.9, y: 0.9), ImagePoint(x: 0.1, y: 0.9)]
        let first = try ManualPanelReferenceBuilder.make(
            photo: photo(), corners: corners, layout: MockSurfaceMaps.microwave)
        let oldTarget = try #require(first.detection.map.buttons.first)
        var state = ManualReferenceState()
        state.replace(with: first)
        state.selectTarget(oldTarget.id)
        #expect(state.selectedTarget?.id == oldTarget.id)

        let newButton = SurfaceMap.Button(label: "New target", bounds: oldTarget.bounds,
                                          confidence: 1)
        let second = try ManualPanelReferenceBuilder.make(
            photo: photo(), corners: corners,
            layout: SurfaceMap(buttons: [newButton], confidence: 1))
        state.replace(with: second)
        #expect(state.selectedTargetID == nil)
        state.selectTarget(oldTarget.id)
        #expect(state.selectedTargetID == nil)
        state.selectTarget(newButton.id)
        #expect(state.selectedTarget?.id == newButton.id)
    }

    @MainActor
    @Test("a delayed old diagnostic result stays cleared after replacement")
    func delayedOldResultIsIgnored() {
        let model = TrackingDebugModel()
        let result = TrackingDiagnostics(timestamp: Date(), status: .notDetected)
        model.clearDisplayedResults()
        model.accept(result, from: 1)
        #expect(model.framesProcessed == 1)

        model.clearDisplayedResults()
        model.accept(result, from: 1)
        #expect(model.latest?.status == nil)
        #expect(model.assessment == nil)
        #expect(model.framesProcessed == 0)
        model.accept(result, from: 2)
        #expect(model.framesProcessed == 1)
    }
}
