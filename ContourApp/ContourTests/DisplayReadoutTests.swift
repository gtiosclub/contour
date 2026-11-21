import ContourCore
import ContourFeedback
import ContourMocks
import Foundation
import Testing
@testable import ContourApp

@MainActor
@Suite("Display readout")
struct DisplayReadoutTests {
    private func pipeline(
        surfaceUnderstanding: any ContourCore.SurfaceUnderstanding = MockSurfaceUnderstanding()
    ) -> ContourPipeline {
        ContourPipeline(
            surfaceUnderstanding: surfaceUnderstanding,
            tracking: MockTrackingSource(),
            feedback: PrintingFeedbackEngine(isPrinting: false),
            liveComponents: []
        )
    }

    @Test("A readable display is appended to the ready status")
    func readableDisplay() async {
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline())
        model.displaySentence = { _ in "The display says 1:30." }

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(model.status == "Panel ready. Say a button name or choose one below. The display says 1:30.")
    }

    @Test("An unreadable display leaves the ready status unchanged")
    func unreadableDisplay() async {
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline())
        model.displaySentence = { _ in nil }

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(model.status == "Panel ready. Say a button name or choose one below.")
    }

    @Test("A failed scan does not read the display")
    func failedScan() async {
        let model = CameraLaunchModel(
            camera: CameraService(),
            pipeline: pipeline(surfaceUnderstanding: FailingMenuSurface())
        )
        var readCount = 0
        model.displaySentence = { _ in
            readCount += 1
            return "The display says 1:30."
        }

        await model.setActive(true).value
        model.scan()
        await model.waitForWork()

        #expect(readCount == 0)
    }

    @Test("Stopping during a display read preserves the stopped status")
    func stopDuringDisplayRead() async {
        let gate = ListeningGate()
        let model = CameraLaunchModel(camera: CameraService(), pipeline: pipeline())
        model.displaySentence = { _ in
            gate.started()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return nil
            }
            return nil
        }

        await model.setActive(true).value
        model.scan()
        await gate.waitForStart()
        model.stop()
        await model.waitForWork()

        #expect(model.status == "Stopped. Say a button name, choose a button, or scan again.")
    }

    @Test("Empty photo data has no display sentence")
    func emptyPhoto() async throws {
        let photo = PanelPhoto(
            data: Data(),
            pixelSize: PixelSize(width: 100, height: 100),
            timestamp: Date()
        )
        let reference = try PanelReference(
            photo: photo,
            detection: PanelDetection(
                referencePhotoID: photo.id,
                quad: .fullFrame,
                map: MockSurfaceMaps.microwave
            )
        )

        let sentence = await DisplayReadout.sentence(for: reference)

        #expect(sentence == nil)
    }
}

@MainActor
private final class ListeningGate {
    private var began = false
    private var waiter: CheckedContinuation<Void, Never>?

    func started() {
        began = true
        waiter?.resume()
        waiter = nil
    }

    func waitForStart() async {
        if began { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private struct FailingMenuSurface: ContourCore.SurfaceUnderstanding {
    func detectPanel(from photo: PanelPhoto) async throws -> PanelDetection {
        throw NSError(
            domain: "MenuScan",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No panel detected"]
        )
    }
}
