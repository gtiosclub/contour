import ContourCore
import ContourMocks
import Foundation
import Testing
import Tracking
import UIKit
@testable import ContourApp

@MainActor
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

    @Test("A manually marked target is normalized against the marked panel, not the photo")
    func manualTargetUsesPanelSpace() throws {
        let corners = [ImagePoint(x: 0.2, y: 0.1), ImagePoint(x: 0.8, y: 0.1),
                       ImagePoint(x: 0.8, y: 0.9), ImagePoint(x: 0.2, y: 0.9)]
        let reference = try ManualTrackingReferenceBuilder.make(photo: photo(), corners: corners,
            target: ImagePoint(x: 0.35, y: 0.7))
        let button = try #require(reference.detection.map.buttons.first)
        #expect(reference.detection.map.buttons.count == 1)
        #expect(button.label == "Manual target")
        #expect(abs(button.bounds.center.x - 0.25) < 1e-9)
        #expect(abs(button.bounds.center.y - 0.75) < 1e-9)
        #expect(reference.photo.id == reference.detection.referencePhotoID)
        #expect(reference.detection.quad != .fullFrame)
    }

    @Test("A target outside the marked panel is rejected")
    func manualTargetOutsidePanelIsRejected() {
        let corners = [ImagePoint(x: 0.2, y: 0.1), ImagePoint(x: 0.8, y: 0.1),
                       ImagePoint(x: 0.8, y: 0.9), ImagePoint(x: 0.2, y: 0.9)]
        #expect(throws: ManualTrackingReferenceBuilder.BuildError.targetOutsidePanel) {
            try ManualTrackingReferenceBuilder.make(photo: photo(), corners: corners,
                target: ImagePoint(x: 0.05, y: 0.5))
        }
    }

    @Test("A crossed panel cannot initialize the manual tracking test")
    func manualTargetRejectsCrossedPanel() {
        let corners = [ImagePoint(x: 0.2, y: 0.1), ImagePoint(x: 0.8, y: 0.9),
                       ImagePoint(x: 0.8, y: 0.1), ImagePoint(x: 0.2, y: 0.9)]
        #expect(throws: ManualTrackingReferenceBuilder.BuildError.invalidPanel) {
            try ManualTrackingReferenceBuilder.make(photo: photo(), corners: corners,
                target: ImagePoint(x: 0.5, y: 0.5))
        }
    }

    @Test("Manual setup guides to its marked target even when Surface cannot detect a panel")
    func manualSetupBypassesSurface() async throws {
        let corners = [ImagePoint(x: 0.2, y: 0.1), ImagePoint(x: 0.8, y: 0.1),
                       ImagePoint(x: 0.8, y: 0.9), ImagePoint(x: 0.2, y: 0.9)]
        let reference = try ManualTrackingReferenceBuilder.make(photo: photo(), corners: corners,
            target: ImagePoint(x: 0.5, y: 0.5))
        let target = try #require(reference.detection.map.buttons.first)
        let feedback = PrintingFeedbackEngine(isPrinting: false)
        let pipeline = ContourPipeline(
            surfaceUnderstanding: MockSurfaceUnderstanding(failure: .noPanelFound),
            tracking: MockTrackingSource(target: PanelPoint(x: 0.5, y: 0.5),
                                         steps: 3, interval: .milliseconds(1)),
            feedback: feedback, liveComponents: [])
        await pipeline.replaceReference(with: reference)
        #expect(pipeline.canGuide)
        await pipeline.guide(to: target)
        #expect(await feedback.outcomes.last == .arrived)
        #expect(pipeline.panelReference?.photo.id == reference.photo.id)
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
