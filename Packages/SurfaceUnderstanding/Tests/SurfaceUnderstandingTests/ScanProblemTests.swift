//
//  ScanProblemTests.swift
//  SurfaceUnderstanding - Surface / Labels
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
        .aim(target: "Start", advice: .moveCloser),
        .cantRead(target: "Start"),
        .notOnPanel(target: "Start")
    ]

    let messages = problems.map(\.spoken)

    #expect(messages.allSatisfy { !$0.isEmpty })
    #expect(Set(messages).count == messages.count)
    #expect(ScanProblem.aim(target: "Start", advice: .moveCloser).spoken == "I couldn't find Start. Move closer")
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

@Test("near misses are classified through after")
func scanProblemNearMissesThroughAfter() {
    let photo = testPhoto()
    let original = MockSurfaceMaps.microwave

    func detection(replacing oldLabel: String, with newLabel: String?) -> PanelDetection {
        let buttons = original.buttons.map { button in
            SurfaceMap.Button(
                id: button.id,
                label: button.label == oldLabel ? newLabel : button.label,
                bounds: button.bounds,
                confidence: button.confidence
            )
        }

        let map = SurfaceMap(
            buttons: buttons,
            confidence: original.confidence
        )

        return testDetection(photo: photo, quad: neatQuad, map: map)
    }

    let tart = detection(replacing: "Start", with: "TART")
    #expect(
        ScanProblem.after(tart, photo: photo, target: "Start")
            == .cantRead(target: "Start")
    )

    let missing = detection(replacing: "Start", with: nil)
    #expect(
        ScanProblem.after(missing, photo: photo, target: "Start")
            == .notOnPanel(target: "Start")
    )

    let timer = detection(replacing: "Popcorn", with: "Timer")
    #expect(
        ScanProblem.after(timer, photo: photo, target: "time")
            == .notOnPanel(target: "time")
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
    #expect(
        ScanProblem.after(detection, photo: photo, target: "Pizza")
            == .aim(target: "Pizza", advice: .moveCloser)
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

@Test("Angle requires moving closer for a missing target")
func scanProblemAngleAim() {
    let photo = testPhoto()
    let quad = testQuad(
        (0.38, 0.28),
        (0.71, 0.27),
        (0.66, 0.70),
        (0.39, 0.80)
    )

    let detection = testDetection(photo: photo, quad: quad)

    #expect(
        ScanProblem.after(detection, photo: photo, target: "Pizza")
            == .aim(target: "Pizza", advice: .moveCloser)
    )

    #expect(
        ScanProblem.after(detection, photo: photo, target: "Start") == nil
    )
}

@Test("Angled panel advice works for upright and rotated photos")
func scanProblemAngledOrientations() {
    let quad = testQuad(
        (0.36, 0.04),
        (0.70, 0.05),
        (0.63, 0.80),
        (0.20, 0.95)
    )

    for photo in [
        testPhoto(orientation: .up, width: 720, height: 1280),
        testPhoto(orientation: .right, width: 1280, height: 720)
    ] {
        let detection = testDetection(photo: photo, quad: quad)

        #expect(
            ScanProblem.after(detection, photo: photo, target: "Pizza")
                == .aim(target: "Pizza", advice: .tooAngled)
        )
    }
}

@Test("Framing advice takes priority over an OCR near miss")
func scanProblemGlarePriority() {
    let photo = testPhoto()
    let quad = testQuad(
        (0.41, 0.12),
        (0.90, 0.11),
        (0.89, 0.84),
        (0.02, 0.87)
    )

    let original = MockSurfaceMaps.microwave

    let changedButtons = original.buttons.map { button in
        SurfaceMap.Button(
            id: button.id,
            label: button.label == "Start" ? "SIART" : button.label,
            bounds: button.bounds,
            confidence: button.confidence
        )
    }

    let map = SurfaceMap(
        buttons: changedButtons,
        confidence: original.confidence
    )

    let detection = testDetection(photo: photo, quad: quad, map: map)

    #expect(
        ScanProblem.after(detection, photo: photo, target: "Pizza")
            == .aim(target: "Pizza", advice: .tooAngled)
    )

    #expect(
        ScanProblem.after(detection, photo: photo, target: "Start")
            == .aim(target: "Start", advice: .tooAngled)
    )
}



