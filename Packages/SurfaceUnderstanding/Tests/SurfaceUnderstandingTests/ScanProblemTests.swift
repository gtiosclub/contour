
//
//  ScanProblemTests.swift
//  SurfaceUnderstandingTests
//

import ContourCore
import ContourMocks
import Foundation
import Testing
@testable import SurfaceUnderstanding

private func testPhoto(
    orientation: PhotoOrientation = .up,
    width: Int = 720,
    height: Int = 1280
) -> PanelPhoto {
    PanelPhoto(
        data: Data(),
        pixelSize: PixelSize(width: width, height: height),
        orientation: orientation,
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

private func testQuad(
    _ tl: (Double, Double),
    _ tr: (Double, Double),
    _ br: (Double, Double),
    _ bl: (Double, Double)
) -> PanelQuad {
    PanelQuad(
        topLeft: ImagePoint(x: tl.0, y: tl.1),
        topRight: ImagePoint(x: tr.0, y: tr.1),
        bottomRight: ImagePoint(x: br.0, y: br.1),
        bottomLeft: ImagePoint(x: bl.0, y: bl.1)
    )
}

private let neatQuad = testQuad(
    (0.22, 0.02),
    (0.75, 0.02),
    (0.74, 0.92),
    (0.24, 0.92)
)

private func testDetection(
    photo: PanelPhoto,
    quad: PanelQuad = neatQuad,
    map: SurfaceMap = MockSurfaceMaps.microwave
) -> PanelDetection {
    PanelDetection(
        referencePhotoID: photo.id,
        quad: quad,
        map: map
    )
}

@Test("scan errors map to the correct problems")
func scanProblemErrors() {
    #expect(ScanProblem.after(SurfaceUnderstandingError.noPanelFound) == .noPanel)
    #expect(ScanProblem.after(SurfaceUnderstandingError.undecodableImage) == .scanFailed)
    #expect(ScanProblem.after(SurfaceUnderstandingError.underlying("Vision failed")) == .scanFailed)
    #expect(ScanProblem.after(SurfaceUnderstandingError.cancelled) == nil)
    #expect(ScanProblem.after(CancellationError()) == nil)
    #expect(ScanProblem.after(PanelReference.ReferenceError.photoMismatch) == .scanFailed)
}

@Test("one-letter OCR errors are recognized as near misses")
func scanProblemNearMisses() {
    let original = MockSurfaceMaps.microwave

    func mapWithLabel(_ label: String?) -> SurfaceMap {
        let buttons = original.buttons.map { button in
            SurfaceMap.Button(
                id: button.id,
                label: button.label == "Start" ? label : button.label,
                bounds: button.bounds,
                confidence: button.confidence
            )
        }

        return SurfaceMap(buttons: buttons, confidence: original.confidence)
    }

    #expect(ScanProblem.isNearMiss(target: "Start", in: mapWithLabel("TART")))
    #expect(ScanProblem.isNearMiss(target: "Start", in: mapWithLabel("SIART")))
    #expect(ScanProblem.isNearMiss(target: "Start", in: mapWithLabel("STARTS")))

    #expect(!ScanProblem.isNearMiss(target: "Start", in: mapWithLabel("START")))
    #expect(!ScanProblem.isNearMiss(target: "Start", in: mapWithLabel(nil)))
    #expect(!ScanProblem.isNearMiss(target: "Start", in: mapWithLabel("STOP")))
    #expect(!ScanProblem.isNearMiss(target: "time", in: mapWithLabel("Timer")))
}

@Test("spoken messages are nonempty and distinct")
func scanProblemSpokenMessages() {
    let problems: [ScanProblem] = [
        .noPanel,
        .scanFailed,
        .panelCutOff,
        .noButtons,
        .cantRead(target: "Start"),
        .notOnPanel(target: "Start")
    ]

    let messages = problems.map(\.spoken)

    #expect(messages.allSatisfy { !$0.isEmpty })
    #expect(Set(messages).count == messages.count)
}

@Test("full-frame detection reports a cut-off panel")
func scanProblemFullFrame() {
    let photo = testPhoto()
    let detection = testDetection(photo: photo, quad: .fullFrame)

    #expect(ScanProblem.after(detection, photo: photo, target: "Start") == .panelCutOff)
    #expect(ScanProblem.after(detection, photo: photo, target: nil) == .panelCutOff)
}

@Test("successful target matching produces no problem")
func scanProblemTargetFound() {
    let photo = testPhoto()
    let detection = testDetection(photo: photo)

    #expect(ScanProblem.after(detection, photo: photo, target: "Start") == nil)
    #expect(ScanProblem.after(detection, photo: photo, target: "Popcorn") == nil)
    #expect(ScanProblem.after(detection, photo: photo, target: nil) == nil)
}

@Test("missing target reports notOnPanel")
func scanProblemTargetMissing() {
    let photo = testPhoto()
    let detection = testDetection(photo: photo)

    #expect(
        ScanProblem.after(detection, photo: photo, target: "Pizza")
            == .notOnPanel(target: "Pizza")
    )
}

@Test("an empty map reports noButtons")
func scanProblemNoButtons() {
    let photo = testPhoto()

    let emptyMap = SurfaceMap(
        buttons: [],
        confidence: 0.94
    )

    let detection = testDetection(photo: photo, map: emptyMap)

    #expect(ScanProblem.after(detection, photo: photo, target: "Start") == .noButtons)
    #expect(ScanProblem.after(detection, photo: photo, target: nil) == .noButtons)
}

@Test("an OCR near miss reports cantRead")
func scanProblemCantRead() {
    let photo = testPhoto()
    let original = MockSurfaceMaps.microwave

    let buttons = original.buttons.map { button in
        SurfaceMap.Button(
            id: button.id,
            label: button.label == "Start" ? "SIART" : button.label,
            bounds: button.bounds,
            confidence: button.confidence
        )
    }

    let map = SurfaceMap(buttons: buttons, confidence: original.confidence)
    let detection = testDetection(photo: photo, map: map)

    #expect(
        ScanProblem.after(detection, photo: photo, target: "Start")
            == .cantRead(target: "Start")
    )
}


@Test(
    "synthetic full-frame panel reports panelCutOff",
    .enabled(
        if: TextRecognitionCheck.works,
        TextRecognitionCheck.skipReason
    ),
    TextRecognitionCheck.timeLimit
)
func scanProblemSyntheticFullFrame() async throws {
    let (photo) = try SyntheticPanel.photo()

    let detection = try await LiveSurfaceUnderstanding()
        .detectPanel(from: photo)

    let problem = ScanProblem.after(
        detection,
        photo: photo,
        target: "Start"
    )

    #expect(problem == .panelCutOff)
}


@Test(
    "synthetic small panel recognizes Start",
    .enabled(
        if: TextRecognitionCheck.works,
        TextRecognitionCheck.skipReason
    ),
    TextRecognitionCheck.timeLimit
)
func scanProblemSyntheticSmallPanel() async throws {
    let (photo, _) = try SyntheticPanel.smallPanelPhoto(
        scale: 0.3
    )

    let detection = try await LiveSurfaceUnderstanding()
        .detectPanel(from: photo)

    #expect(
        ScanProblem.after(
            detection,
            photo: photo,
            target: "Start"
        ) == nil
    )
}

@Test("panelCutOff takes priority over noButtons")
func scanProblemPriority() {
    let photo = testPhoto()

    let emptyMap = SurfaceMap(
        buttons: [],
        confidence: 0.9
    )

    let detection = testDetection(
        photo: photo,
        quad: .fullFrame,
        map: emptyMap
    )

    #expect(
        ScanProblem.after(
            detection,
            photo: photo,
            target: "Start"
        ) == .panelCutOff
    )
}

@Test("near miss checks individual words in labels")
func scanProblemMultiwordNearMiss() {
    let original = MockSurfaceMaps.microwave

    let buttons = original.buttons.map { button in
        SurfaceMap.Button(
            id: button.id,
            label: button.label == "Start"
                ? "Press SIART Now"
                : button.label,
            bounds: button.bounds,
            confidence: button.confidence
        )
    }

    let map = SurfaceMap(
        buttons: buttons,
        confidence: original.confidence
    )

    #expect(
        ScanProblem.isNearMiss(
            target: "Start",
            in: map
        )
    )
}

@Test("near miss requires exactly one edit")
func scanProblemEditDistance() {
    let original = MockSurfaceMaps.microwave

    func mapWithStartLabel(_ label: String) -> SurfaceMap {
        let buttons = original.buttons.map { button in
            SurfaceMap.Button(
                id: button.id,
                label: button.label == "Start"
                    ? label
                    : button.label,
                bounds: button.bounds,
                confidence: button.confidence
            )
        }

        return SurfaceMap(
            buttons: buttons,
            confidence: original.confidence
        )
    }

    #expect(
        ScanProblem.isNearMiss(
            target: "Start",
            in: mapWithStartLabel("TART")
        )
    )

    #expect(
        ScanProblem.isNearMiss(
            target: "Start",
            in: mapWithStartLabel("SIART")
        )
    )

    #expect(
        !ScanProblem.isNearMiss(
            target: "Start",
            in: mapWithStartLabel("XYZ")
        )
    )
}



