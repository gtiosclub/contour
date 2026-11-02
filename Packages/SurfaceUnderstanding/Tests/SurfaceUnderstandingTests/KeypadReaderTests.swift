//
//  KeypadReaderTests.swift
//  SurfaceUnderstandingTests — Surface / Labels
//
//  The grid fit, the merge and the time caps on hand-placed words, with no
//  Vision, so these run on CI. Vision only comes in for the generated keypad and
//  for the recorded camera frames, which only run when you point at them.
//

import ContourCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SurfaceUnderstanding

private let frame = CGSize(width: 720, height: 1280)

/// A word centred on (x, y), in pixels.
private func word(_ text: String, x: Double, y: Double) -> LabelReader.Word {
    LabelReader.Word(text: text, left: x - 8, right: x + 8, top: y - 8, bottom: y + 8)
}

/// One word per digit, each at its place on a keypad with these steps.
private func keypad(_ digits: String, origin: CGPoint = CGPoint(x: 200, y: 500),
                    column: CGVector = CGVector(dx: 60, dy: 0),
                    row: CGVector = CGVector(dx: 0, dy: 50)) -> [LabelReader.Word] {
    digits.map { digit in
        let key = KeypadReader.layout[digit]!
        return word(String(digit), x: origin.x + column.dx * key.column + row.dx * key.row,
                    y: origin.y + column.dy * key.column + row.dy * key.row)
    }
}

/// `words` as a grid, or nil if they don't make a keypad.
private func grid(_ words: [LabelReader.Word]) -> KeypadReader.Grid? {
    KeypadReader.keypad(in: words, size: frame)
}

private func expectClose(_ point: CGPoint, x: Double, y: Double, within tolerance: Double = 0.01,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(point.x - x) < tolerance && abs(point.y - y) < tolerance, "got \(point), wanted (\(x), \(y))",
            sourceLocation: sourceLocation)
}

// MARK: - The fit

@Test("a full keypad fits, with the 0 under the 8")
func fullKeypadFits() throws {
    let found = try #require(grid(keypad("1234567890")))
    expectClose(found.centre(of: "1"), x: 200, y: 500)
    expectClose(found.centre(of: "9"), x: 320, y: 600)
    expectClose(found.centre(of: "0"), x: 260, y: 650)
    #expect(found.read == Set("1234567890"))
}

@Test("a keypad seen at an angle fits, and fills in the digits it didn't read")
func skewedKeypadFits() throws {
    let column = CGVector(dx: 50, dy: 8), row = CGVector(dx: 10, dy: 45)
    let found = try #require(grid(keypad("124578", column: column, row: row)))
    #expect(found.read == Set("124578"))
    expectClose(found.centre(of: "3"), x: 300, y: 516)
    expectClose(found.centre(of: "0"), x: 280, y: 643)
}

@Test("a digit off the grid is dropped, and its key still lands in the right place")
func badReadIsDropped() throws {
    var words = keypad("12345689")
    words.append(word("7", x: 200 + 20, y: 600))   // a third of a column off
    let found = try #require(grid(words))
    #expect(found.read == Set("12345689"))
    expectClose(found.centre(of: "7"), x: 200, y: 600)
}

@Test("the fit gives the same answer as the prototype on a real frame's digits")
func matchesThePrototype() throws {
    // Frame 42's digits as read by the tiles. gridfit.py drops the 7 and fills it.
    let read: [Character: CGPoint] = [
        "1": CGPoint(x: 345.582, y: 862.663), "2": CGPoint(x: 382.667, y: 861.604), "3": CGPoint(x: 414.333, y: 860.882),
        "4": CGPoint(x: 346.493, y: 894.634), "5": CGPoint(x: 383.667, y: 894.239), "6": CGPoint(x: 419.0, y: 893.401),
        "7": CGPoint(x: 359.333, y: 924.445), "8": CGPoint(x: 384.0, y: 924.278), "9": CGPoint(x: 420.333, y: 923.278),
    ]
    let found = try #require(KeypadReader.fit(read))
    #expect(found.read == Set("12345689"))
    #expect(found.isKeypad(in: frame))
    expectClose(found.centre(of: "7"), x: 349.263, y: 925.639)
    expectClose(found.centre(of: "0"), x: 386.487, y: 956.084)
}

@Test("the median of a digit's readings places it, so a stray one doesn't move the key")
func repeatedReadsUseTheMedian() {
    let read = KeypadReader.digits(in: [word("5", x: 100, y: 200), word("5", x: 102, y: 202), word("5", x: 400, y: 900),
                                        word("55", x: 10, y: 10), word("Clock", x: 20, y: 20)])
    #expect(read.count == 1)
    #expect(read["5"] == CGPoint(x: 102, y: 202))
}

@Test("four digits aren't enough")
func tooFewDigits() {
    #expect(grid(keypad("1259")) == nil)
}

@Test("digits from only two of the three rows don't fit")
func onlyTwoRows() {
    #expect(grid(keypad("123456")) == nil)
    #expect(grid(keypad("456789")) == nil)
    #expect(grid(keypad("1234560")) == nil)
}

@Test("digits in one long row don't fit")
func oneRow() {
    let words = "1234567890".enumerated().map { word(String($1), x: 60 + 60 * Double($0), y: 500) }
    #expect(grid(words) == nil)
}

@Test("digits in one long column don't fit")
func oneColumn() {
    let words = "1234567890".enumerated().map { word(String($1), x: 300, y: 300 + 60 * Double($0)) }
    #expect(grid(words) == nil)
}

@Test("a calculator keypad, 7-8-9 on top, doesn't fit")
func calculatorLayout() {
    func place(_ digits: String) -> [LabelReader.Word] {
        digits.map { digit in
            let value = digit == "0" ? 10 : Int(String(digit))!
            let (column, row) = digit == "0" ? (1.0, 3.0) : (Double((value - 1) % 3), Double(2 - (value - 1) / 3))
            return word(String(digit), x: 200 + 60 * column, y: 500 + 50 * row)
        }
    }
    #expect(grid(place("1234567890")) == nil)
    #expect(grid(place("123456789")) == nil)
    #expect(grid(place("124578")) == nil)
}

@Test("a keypad running off the frame doesn't fit")
func offTheFrame() {
    #expect(grid(keypad("123456789", origin: CGPoint(x: 680, y: 500))) == nil)
    #expect(grid(keypad("123456789", origin: CGPoint(x: 200, y: 1200))) == nil)
}

// MARK: - The buttons

@Test("keys land on the quad's panel space, and a filled-in digit is less sure than a read one")
func keysAreInPanelSpace() throws {
    let found = try #require(grid(keypad("124578")))
    // The quad runs from (100, 400) to (500, 800), so x is (px - 100) / 400.
    let quad = PanelQuad(topLeft: ImagePoint(x: 100.0 / 720, y: 400.0 / 1280), topRight: ImagePoint(x: 500.0 / 720, y: 400.0 / 1280),
                         bottomRight: ImagePoint(x: 500.0 / 720, y: 800.0 / 1280), bottomLeft: ImagePoint(x: 100.0 / 720, y: 800.0 / 1280))
    let keys = try #require(KeypadReader.keyButtons(of: found, size: frame, panel: quad))
    #expect(keys.compactMap(\.label).sorted() == (0...9).map(String.init))

    let two = try #require(keys.first { $0.label == "2" })
    #expect(abs(two.bounds.center.x - 0.4) < 1e-6 && abs(two.bounds.center.y - 0.25) < 1e-6)
    #expect(abs(two.bounds.width - 0.15) < 1e-6 && abs(two.bounds.height - 0.125) < 1e-6)
    #expect(two.confidence == 0.5)
    #expect(keys.first { $0.label == "0" }?.confidence == 0.3)
    #expect(keys.allSatisfy { $0.confidence < 1 })

    // Next to each other, not on top of each other.
    let one = try #require(keys.first { $0.label == "1" })
    #expect(abs(one.bounds.maxX - two.bounds.minX) < 1e-6)
}

@Test("a quad turned a quarter still gives keys a real size")
func turnedQuad() throws {
    let found = try #require(grid(keypad("124578")))
    // Logical top-left is the image's top-right, as glare_microwave.jpg comes back.
    let quad = PanelQuad(topLeft: ImagePoint(x: 500.0 / 720, y: 400.0 / 1280), topRight: ImagePoint(x: 500.0 / 720, y: 800.0 / 1280),
                         bottomRight: ImagePoint(x: 100.0 / 720, y: 800.0 / 1280), bottomLeft: ImagePoint(x: 100.0 / 720, y: 400.0 / 1280))
    let keys = try #require(KeypadReader.keyButtons(of: found, size: frame, panel: quad))
    let two = try #require(keys.first { $0.label == "2" })
    #expect(abs(two.bounds.width - 0.125) < 1e-6 && abs(two.bounds.height - 0.15) < 1e-6)
}

@Test("a key off the returned quad means no keys at all")
func keyOffTheQuad() throws {
    let found = try #require(grid(keypad("124578")))
    // Holds every key but the 0, which sits at y = 650.
    let quad = PanelQuad(topLeft: ImagePoint(x: 100.0 / 720, y: 400.0 / 1280), topRight: ImagePoint(x: 500.0 / 720, y: 400.0 / 1280),
                         bottomRight: ImagePoint(x: 500.0 / 720, y: 620.0 / 1280), bottomLeft: ImagePoint(x: 100.0 / 720, y: 620.0 / 1280))
    #expect(KeypadReader.keyButtons(of: found, size: frame, panel: quad) == nil)
}

// MARK: - Merging with what the scan found

/// Keys in a simple grid on the panel: the 1 at (0.1, 0.1), steps of 0.2 each way,
/// so a cell is 0.2 square and the 0 is at (0.3, 0.7).
private func panelKeys() throws -> [SurfaceMap.Button] {
    let grid = KeypadReader.Grid(origin: CGPoint(x: 72, y: 128), columnStep: CGVector(dx: 144, dy: 0),
                                 rowStep: CGVector(dx: 0, dy: 256), read: Set("123456789"))
    return try #require(KeypadReader.keyButtons(of: grid, size: frame, panel: .fullFrame))
}

private func box(_ label: String?, x: Double, y: Double, confidence: Double = 1) -> SurfaceMap.Button {
    SurfaceMap.Button(label: label, bounds: PanelRect(x: x - 0.02, y: y - 0.02, width: 0.04, height: 0.04), confidence: confidence)
}

@Test("the grid replaces every digit label, wherever it was")
func digitLabelsAreReplaced() throws {
    let keys = try panelKeys()
    // A 3 key labelled 6 (it took the line below it), and a digit out by the display.
    let merged = KeypadReader.merging(keys, into: [box("6", x: 0.3, y: 0.1), box("1", x: 0.9, y: 0.9)])
    #expect(merged.map(\.id) == keys.map(\.id))
}

@Test("an unlabelled box in a key's cell goes, and one elsewhere stays")
func unlabelledBoxes() throws {
    let keys = try panelKeys()
    let outside = box(nil, x: 0.9, y: 0.9)
    let merged = KeypadReader.merging(keys, into: [box(nil, x: 0.3, y: 0.3), outside])
    #expect(merged.count == keys.count + 1)
    #expect(merged.contains { $0.id == outside.id })
}

@Test("a box in a key's cell can't stay a Start target")
func startInACellGoes() throws {
    let keys = try panelKeys()
    let map = SurfaceMap(buttons: KeypadReader.merging(keys, into: [box("Start", x: 0.3, y: 0.3), box("start pause", x: 0.1, y: 0.1)]), confidence: 1)
    #expect(map.buttons.count == keys.count)
    #expect(TargetMatcher().match("start", in: map) == nil)
}

@Test("a word on a digit key stays beside the digit, and each request finds its own")
func wordOnADigitKeyStays() throws {
    let keys = try panelKeys()
    let popcorn = box("Popcorn", x: 0.1, y: 0.1, confidence: 0.5)
    let map = SurfaceMap(buttons: KeypadReader.merging(keys, into: [popcorn]), confidence: 1)
    #expect(TargetMatcher().match("popcorn", in: map)?.button.id == popcorn.id)
    #expect(TargetMatcher().match("1", in: map)?.button.label == "1")
    #expect(TargetMatcher().match("one", in: map)?.button.label == "1")
}

@Test("a misread of the digit goes with it, but real words in other places stay")
func misreadsGoWordsStay() throws {
    let keys = try panelKeys()
    let kept = [box("Memory", x: 0.3, y: 0.7), box("1:35", x: 0.9, y: 0.05), box("Clock", x: 0.9, y: 0.5), box("Start Pause", x: 0.9, y: 0.9)]
    let merged = KeypadReader.merging(keys, into: kept + [box("З", x: 0.5, y: 0.1), box("2 5", x: 0.1, y: 0.3), box("00", x: 0.3, y: 0.5)])
    #expect(merged.map(\.id) == kept.map(\.id) + keys.map(\.id))
}

@Test("digits are found by digit and by name once they're on the map")
func digitsAreMatchable() throws {
    let map = SurfaceMap(buttons: KeypadReader.merging(try panelKeys(), into: [box("Add 30 Sec", x: 0.9, y: 0.7)]), confidence: 1)
    #expect(TargetMatcher().match("5", in: map)?.button.label == "5")
    #expect(TargetMatcher().match("five", in: map)?.button.label == "5")
    #expect(TargetMatcher().match("30", in: map)?.button.label != "3")
}

// MARK: - Start

private let startGrid = KeypadReader.Grid(origin: CGPoint(x: 200, y: 500), columnStep: CGVector(dx: 60, dy: 0),
                                          rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))

@Test("a Start word below the keypad is Start")
func startBelowTheGrid() {
    let start = word("START", x: 320, y: 720)
    #expect(KeypadReader.startWord(in: [word("Clock", x: 200, y: 650), start], grid: startGrid) == start)
    #expect(KeypadReader.startWord(in: [word("Start/Pause", x: 320, y: 720)], grid: startGrid) != nil)
}

@Test("Start above the keypad's first row is the display, not a key")
func startAboveTheGridIsRejected() {
    // microwave-08's display says Start under the clock.
    let display = word("Start", x: 300, y: 200)
    #expect(KeypadReader.startWord(in: [display], grid: startGrid) == nil)
    #expect(KeypadReader.startWord(in: [word("Start", x: 300, y: 500 - 26)], grid: startGrid) == nil)
    // The real one still wins when both are there.
    let key = word("Start", x: 320, y: 720)
    #expect(KeypadReader.startWord(in: [display, key], grid: startGrid) == key)
    // A tilted grid's first row is judged along the grid, not across the image.
    let tilted = KeypadReader.Grid(origin: CGPoint(x: 200, y: 500), columnStep: CGVector(dx: 60, dy: -20),
                                   rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
    #expect(KeypadReader.startWord(in: [word("Start", x: 320, y: 450)], grid: tilted) != nil)
    #expect(KeypadReader.startWord(in: [word("Start", x: 200, y: 450)], grid: tilted) == nil)
}

@Test("a near miss counts for Start only when no exact word is there, and only one edit away")
func nearMatches() {
    for near in ["SVART", "STAR", "SART", "SCART"] {
        #expect(KeypadReader.startWord(in: [word(near, x: 320, y: 720)], grid: startGrid)?.text == near)
    }
    for other in ["STOP", "Star!", "Sta", "Timer", "Tarts"] {
        #expect(KeypadReader.startWord(in: [word(other, x: 320, y: 720)], grid: startGrid) == nil, "\(other)")
    }
    let exact = word("Start", x: 320, y: 760)
    #expect(KeypadReader.startWord(in: [word("STAR", x: 320, y: 720), exact], grid: startGrid) == exact)
    #expect(KeypadReader.startWord(in: [word("STAR", x: 320, y: 200)], grid: startGrid) == nil)
}

@Test("the same word read in several tiles gives one of those readings")
func startFromRepeatedReads() {
    let reads = [word("START", x: 320, y: 720), word("START", x: 321, y: 722), word("START", x: 322, y: 724)]
    #expect(KeypadReader.startWord(in: reads, grid: startGrid) == reads[1])
}

@Test("the Start button is a printed label on the quad, and off the quad there is none")
func startButton() throws {
    let start = word("START", x: 360, y: 640)
    let button = try #require(KeypadReader.startButton(on: start, size: frame, panel: .fullFrame).first)
    #expect(button.label == "Start")
    #expect(button.confidence == 0.5)
    #expect(abs(button.bounds.center.x - 0.5) < 1e-6 && abs(button.bounds.center.y - 0.5) < 1e-6)

    let small = PanelQuad(topLeft: ImagePoint(x: 0, y: 0), topRight: ImagePoint(x: 0.2, y: 0),
                          bottomRight: ImagePoint(x: 0.2, y: 0.2), bottomLeft: ImagePoint(x: 0, y: 0.2))
    #expect(KeypadReader.startButton(on: start, size: frame, panel: small).isEmpty)
}

@Test("the Start crops sit below the keypad and on the image")
func startCrops() {
    let crops = startGrid.startCrops(in: frame)
    #expect(crops.count == 3)
    #expect(crops.allSatisfy { $0.minY > startGrid.centre(of: "0").y && CGRect(origin: .zero, size: frame).contains($0) })
    let low = KeypadReader.Grid(origin: CGPoint(x: 200, y: 1000), columnStep: CGVector(dx: 60, dy: 0),
                                rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
    #expect(low.startCrops(in: frame).allSatisfy { $0.maxY <= frame.height })
}

// MARK: - Time, failure, cancellation

/// Stands in for a Vision call that takes far too long and ignores cancellation:
/// a detached task isn't cancelled along with the one waiting on it.
private func ignoringCancellation() async {
    await Task.detached { try? await Task.sleep(for: .seconds(20)) }.value
}

private let stuck: LabelReader.Recognizer = { _, _ in
    await ignoringCancellation()
    return []
}

private func blankPhoto() throws -> PanelPhoto {
    let context = try #require(CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return PanelPhoto(data: out as Data, pixelSize: PixelSize(width: 300, height: 300), timestamp: .distantPast)
}

private struct Boom: Error {}

@Test("the cap gives back the answer when the work is quicker")
func capPassesTheAnswer() async throws {
    #expect(try await KeypadReader.within(.seconds(5)) { 42 } == 42)
    await #expect(throws: Boom.self) { _ = try await KeypadReader.within(.seconds(5)) { throw Boom() } }
}

@Test("the cap holds even when the work ignores cancellation")
func capHoldsOnStuckWork() async throws {
    let started = ContinuousClock.now
    await #expect(throws: KeypadReader.TimedOut.self) {
        _ = try await KeypadReader.within(.milliseconds(50)) { await ignoringCancellation() }
    }
    #expect(started.duration(to: .now) < .seconds(2))
}

@Test("cancelling the caller returns at once, even when the work ignores it")
func cancellingThrows() async throws {
    let task = Task {
        try await KeypadReader.within(.seconds(60)) { await ignoringCancellation() }
    }
    try await Task.sleep(for: .milliseconds(50))
    let started = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(started.duration(to: .now) < .seconds(2))
}

/// The scan with its keypad reader swapped.
private func scan(_ reader: KeypadReader) -> LiveSurfaceUnderstanding {
    var scan = LiveSurfaceUnderstanding()
    scan.keypadReader = reader
    return scan
}

@Test("a read held to the real caps: 2 s for the panel tiles, 4 s for the lot")
func theRealCaps() {
    #expect(KeypadReader().panelLimit == .seconds(2))
    #expect(KeypadReader().readLimit == .seconds(4))
}

@Test("a stuck read hits either cap and the scan keeps its buttons")
func stuckReadKeepsTheButtons() async throws {
    let buttons = [box("Start", x: 0.5, y: 0.5)]
    for reader in [KeypadReader(recognizer: stuck, panelLimit: .milliseconds(100)),
                   KeypadReader(recognizer: stuck, readLimit: .milliseconds(100))] {
        let started = ContinuousClock.now
        let result = try await scan(reader).addingKeypad(to: buttons, in: try blankPhoto(), panel: .fullFrame)
        #expect(result == buttons)
        #expect(started.duration(to: .now) < .seconds(1.5))
    }
}

@Test("a recognition failure leaves the buttons exactly as they were")
func failedReadKeepsTheButtons() async throws {
    let buttons = [box("Start", x: 0.5, y: 0.5), box(nil, x: 0.1, y: 0.1)]
    let reader = KeypadReader(recognizer: { _, _ in throw Boom() })
    let result = try await scan(reader).addingKeypad(to: buttons, in: try blankPhoto(), panel: .fullFrame)
    #expect(result == buttons)
}

@Test("an undecodable photo leaves the buttons exactly as they were")
func undecodablePhotoKeepsTheButtons() async throws {
    let buttons = [box("Start", x: 0.5, y: 0.5)]
    let junk = PanelPhoto(data: Data([0, 1, 2]), pixelSize: PixelSize(width: 1, height: 1), timestamp: .distantPast)
    let result = try await LiveSurfaceUnderstanding().addingKeypad(to: buttons, in: junk, panel: .fullFrame)
    #expect(result == buttons)
}

@Test("cancelling the scan during the read surfaces as cancelled")
func cancellingTheScan() async throws {
    let photo = try blankPhoto()
    let task = Task {
        try await scan(KeypadReader(recognizer: stuck)).addingKeypad(to: [], in: photo, panel: .fullFrame)
    }
    try await Task.sleep(for: .milliseconds(100))
    let started = ContinuousClock.now
    task.cancel()
    await #expect(throws: SurfaceUnderstandingError.cancelled) { _ = try await task.value }
    #expect(started.duration(to: .now) < .seconds(1.5))
}

/// Counts recognition calls across the tasks that make them.
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Test("no digit in the panel tiles means the whole frame isn't read")
func noDigitsStopsAfterTheFirstStage() async throws {
    let calls = CallCount()
    let reader = KeypadReader(recognizer: { _, _ in
        calls.add()
        return []
    })
    let reading = try await reader.read(in: try blankPhoto(), panel: .fullFrame, adding: [])
    #expect(calls.value == 9)
    #expect(reading.stage == 1)
    #expect(!reading.fit && !reading.added)
}

// MARK: - Vision

/// False when `.accurate` doesn't run here. It sometimes fails to load on macOS 27,
/// which is a reason to skip, not to fail. Also waits out the slow first load.
private func accurateWorks(on photo: PanelPhoto) async throws -> Bool {
    (try? await LabelReader.recognize(try photo.cgImage(), level: .accurate)) != nil
}

/// A busy machine shouldn't fail these on time. The caps have their own tests.
private let unhurried = KeypadReader(panelLimit: .seconds(60), readLimit: .seconds(60))

@Test("a generated keypad gets ten keys on the right digits",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func generatedKeypad() async throws {
    let (photo, keys) = try SyntheticPanel.keypadPhoto()
    guard try await accurateWorks(on: photo) else { return }

    let detection = try await scan(unhurried).detectPanel(from: photo)

    for (digit, key) in keys {
        let target = PanelDetector().rectify(key, within: detection.quad)
        let found = try #require(TargetMatcher().match(String(digit), in: detection.map)?.button)
        #expect(found.bounds.contains(target), "\(digit) at \(found.bounds), wanted \(target)")
        #expect(abs(found.bounds.center.x - target.x) < found.bounds.width / 2 * 0.5)
    }
    let reference = try PanelReference(photo: photo, detection: detection)
    #expect(reference.detection.map == detection.map)
}

@Test("a quad that misses the keypad falls to the whole frame, and adds nothing off the quad",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func quadMissingTheKeypad() async throws {
    let (photo, keys) = try SyntheticPanel.keypadPhoto()
    guard try await accurateWorks(on: photo) else { return }

    // A quad around just the top row: a digit or two to go on, but no three rows.
    let (one, three) = (keys["1"]!, keys["3"]!)
    let quad = PanelQuad(topLeft: ImagePoint(x: one.x - 0.08, y: one.y - 0.04), topRight: ImagePoint(x: three.x + 0.08, y: three.y - 0.04),
                         bottomRight: ImagePoint(x: three.x + 0.08, y: three.y + 0.04), bottomLeft: ImagePoint(x: one.x - 0.08, y: one.y + 0.04))
    let buttons = [box("Popcorn", x: 0.5, y: 0.5)]
    let reading = try await unhurried.read(in: photo, panel: quad, adding: buttons)

    #expect(reading.stage == 2)
    #expect(reading.fit)
    #expect(!reading.added)
    #expect(reading.buttons == buttons)
}

// MARK: - Recorded camera frames

/// Point CONTOUR_FRAMES_DIR at a folder of NAME.jpg with NAME.json beside it, as
/// the app's frame recorder writes them, for a table of what real scans get. The
/// frames aren't in the repo, so this skips everywhere else, CI included.
@Test(
    "real frames scoreboard",
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTOUR_FRAMES_DIR"]?.isEmpty == false,
        "Set CONTOUR_FRAMES_DIR to a folder of recorded camera frames."
    ),
    .timeLimit(.minutes(10))
)
func realFramesScoreboard() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CONTOUR_FRAMES_DIR"]))
    let frames = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jpg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let first = try #require(frames.first)
    guard try await accurateWorks(on: try recordedPhoto(first)) else {
        Issue.record(".accurate text recognition doesn't run on this machine")
        return
    }

    print("| Frame | Quad | Digits | Types 1,3,0 | Start | Seconds |")
    print("| --- | --- | ---: | --- | --- | ---: |")
    var typeable = 0, typeableWithStart = 0, seconds: [Double] = []
    for url in frames {
        let photo = try recordedPhoto(url)
        let started = ContinuousClock.now
        let detection = try await LiveSurfaceUnderstanding().detectPanel(from: photo)
        let duration = started.duration(to: .now).components
        seconds.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)

        let matcher = TargetMatcher()
        let digits = (0...9).filter { matcher.match(String($0), in: detection.map) != nil }.count
        let types = ["1", "3", "0"].allSatisfy { matcher.match($0, in: detection.map) != nil }
        let start = matcher.match("start", in: detection.map) != nil
        typeable += types ? 1 : 0
        typeableWithStart += types && start ? 1 : 0
        print("| \(url.deletingPathExtension().lastPathComponent) | \(detection.quad == .fullFrame ? "full frame" : "quad") | \(digits) | \(types ? "yes" : "no") | \(start ? "yes" : "no") | \(String(format: "%.2f", seconds.last!)) |")
    }
    let middle = seconds.sorted()[seconds.count / 2]
    print("Of \(frames.count) frames: \(typeable) can type 1,3,0 and \(typeableWithStart) also find Start. Median \(String(format: "%.2f", middle)) s, slowest \(String(format: "%.2f", seconds.max() ?? 0)) s. This counts keys on the map; whether they're on the right spot takes an eye on the frame.")
}

private func recordedPhoto(_ url: URL) throws -> PanelPhoto {
    let sidecar = url.deletingPathExtension().appendingPathExtension("json")
    let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
    let size = try #require(meta["pixelSize"] as? [String: Int])
    return PanelPhoto(
        data: try Data(contentsOf: url),
        pixelSize: PixelSize(width: try #require(size["width"]), height: try #require(size["height"])),
        orientation: PhotoOrientation(rawValue: meta["orientation"] as? String ?? "up") ?? .up,
        timestamp: .distantPast
    )
}
