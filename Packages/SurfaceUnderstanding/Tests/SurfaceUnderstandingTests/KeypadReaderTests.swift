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

/// A word centred on (x, y), in pixels, 16 tall.
private func word(_ text: String, x: Double, y: Double, width: Double = 16) -> LabelReader.Word {
    LabelReader.Word(text: text, left: x - width / 2, right: x + width / 2, top: y - 8, bottom: y + 8)
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

@Test("Start beside Delay or Time isn't Start, in either order or on two lines, even misread")
func startWithAnotherWord() {
    // Words 50 wide on a line at y = 720, a space apart, or lines 20 apart.
    for other in ["Delay", "DELAY", "Dela", "Delav", "Time", "TIME", "Tim", "Tine"] {
        for start in ["Start", "START", "otart", "SVART"] {
            for (a, b) in [(word(other, x: 300, y: 720, width: 50), word(start, x: 356, y: 720, width: 50)),
                           (word(other, x: 356, y: 720, width: 50), word(start, x: 300, y: 720, width: 50)),
                           (word(other, x: 320, y: 700, width: 50), word(start, x: 320, y: 720, width: 50)),
                           (word(other, x: 320, y: 740, width: 50), word(start, x: 320, y: 720, width: 50))] {
                #expect(KeypadReader.startWord(in: [a, b], grid: startGrid) == nil, "\(a.text) \(b.text)")
            }
        }
    }
}

@Test("a short piece of Start, cut by a tile edge, still sees Delay or Time on the next line")
func shortStartBesideATallerWord() {
    // A 12 tall piece, with a 28 tall word 30 away: too far for the piece's own height.
    let piece = LabelReader.Word(text: "otart", left: 295, right: 345, top: 714, bottom: 726)
    for other in ["Delay", "Time"] {
        for y in [690.0, 750.0] {
            let taller = LabelReader.Word(text: other, left: 295, right: 345, top: y - 14, bottom: y + 14)
            #expect(KeypadReader.startWord(in: [piece, taller], grid: startGrid) == nil, "\(other) at \(y)")
        }
    }
    #expect(KeypadReader.startWord(in: [piece], grid: startGrid) == piece)
}

@Test("a Start cut out of Re-Start isn't Start")
func startBesideRestartWithAHyphen() {
    for text in ["Re-Start", "RE-START"] {
        let label = word(text, x: 300, y: 720, width: 60)
        let piece = word("Start", x: 340, y: 720, width: 30)
        #expect(KeypadReader.startWord(in: [label, piece], grid: startGrid) == nil, "\(text)")
    }
}

@Test("one word holding Start and Delay or Time isn't Start, but Start/Pause is")
func startInOneWordWithAnother() {
    for text in ["Start/Time", "Time/Start", "Delay/Start", "Start/Delay"] {
        #expect(KeypadReader.startWord(in: [word(text, x: 320, y: 720, width: 80)], grid: startGrid) == nil, "\(text)")
    }
    #expect(KeypadReader.startWord(in: [word("Start/Pause", x: 320, y: 720, width: 80)], grid: startGrid) != nil)
}

@Test("Delay or Time on another key doesn't take away a real Start")
func startNearOtherKeys() {
    let start = word("START", x: 320, y: 720, width: 50)
    let others = [word("Timer", x: 230, y: 720, width: 40),    // the key beside it
                  word("Time", x: 320, y: 670, width: 40),     // the key above it
                  word("Delay", x: 320, y: 770, width: 40)]    // the key below it
    #expect(KeypadReader.startWord(in: others + [start], grid: startGrid) == start)
    // Delay Start on one key and Start on another: the real one is still there.
    let delayed = [word("Delay", x: 200, y: 720, width: 50), word("Start", x: 256, y: 720, width: 50)]
    #expect(KeypadReader.startWord(in: delayed + [start], grid: startGrid) == start)
}

@Test("real words near Start aren't Start, and real misreads of it still are")
func wordsThatLookLikeStart() {
    for other in ["Restart", "RESTART", "estart", "Smart", "SMART", "Stars", "Stat", "Smart/Cook", "ASTART!"] {
        #expect(KeypadReader.startWord(in: [word(other, x: 320, y: 720, width: 50)], grid: startGrid) == nil, "\(other)")
    }
    // What a tile edge can leave of a word, with the whole word read in the next tile.
    for (whole, cut) in [("Restart", "start"), ("Stars", "Star")] {
        let words = [word(whole, x: 320, y: 720, width: 70), word(cut, x: 330, y: 720, width: 50)]
        #expect(KeypadReader.startWord(in: words, grid: startGrid) == nil, "\(cut)")
    }
    // Delay read whole, its Start cut to tart further along the line.
    let delayed = [word("Delay", x: 280, y: 720, width: 50), word("tart", x: 345, y: 720, width: 40)]
    #expect(KeypadReader.startWord(in: delayed, grid: startGrid) == nil)
    // All read off START on the recorded frames.
    for misread in ["SVART", "SYART", "STAR", "TART", "SCART", "SART", "ASTART"] {
        #expect(KeypadReader.startWord(in: [word(misread, x: 320, y: 720, width: 50)], grid: startGrid)?.text == misread)
    }
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

@Test("a keypad at the very bottom of the frame has no Start crop off the image")
func noStartCropOffTheImage() {
    let bottom = KeypadReader.Grid(origin: CGPoint(x: 200, y: 1100), columnStep: CGVector(dx: 60, dy: 0),
                                   rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
    #expect(bottom.isKeypad(in: frame))
    #expect(bottom.startCrops(in: frame).isEmpty)
    let tilted = KeypadReader.Grid(origin: CGPoint(x: 200, y: 1090), columnStep: CGVector(dx: 60, dy: -12),
                                   rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
    #expect(tilted.startCrops(in: frame).allSatisfy { !$0.isEmpty })
}

// MARK: - Time Cook

/// On `startGrid` the 9 is at (320, 600), so this is the key below it. Lines 20 apart.
private func stacked(_ first: String = "Time", _ second: String = "Cook", x: Double = 320, y: Double = 690) -> [LabelReader.Word] {
    [word(first, x: x, y: y, width: 40), word(second, x: x, y: y + 20, width: 40)]
}

/// Words on one line at y, each 40 wide, a small gap apart, starting at x.
private func line(_ words: String..., x: Double = 300, y: Double = 690) -> [LabelReader.Word] {
    words.enumerated().map { word($1, x: x + 46 * Double($0), y: y, width: 40) }
}

private func timeCook(_ words: [LabelReader.Word]) -> LabelReader.Word? {
    KeypadReader.timeCookLabel(in: words, grid: startGrid)
}

@Test("Time over Cook, or Time then Cook on one line, is one label")
func timeCookTogether() {
    #expect(timeCook(stacked()) == LabelReader.Word(text: "Time Cook", left: 300, right: 340, top: 682, bottom: 718))
    #expect(timeCook(line("Time", "Cook")) == LabelReader.Word(text: "Time Cook", left: 280, right: 366, top: 682, bottom: 698))
    #expect(timeCook(stacked("TIME", "COOK")) != nil)
    #expect(timeCook(stacked("Time:", "Cook.")) != nil)
}

@Test("the printed Magic Chef words, tilted as a real frame is, give the one real key")
func timeCookOnTheMagicChef() throws {
    // Frame 2's readings, with its own grid. The rest of the panel is close by.
    let grid = KeypadReader.Grid(origin: CGPoint(x: 280, y: 628), columnStep: CGVector(dx: 72, dy: -1),
                                 rowStep: CGVector(dx: 0, dy: 56), read: Set("124567890"))
    let words = [word("Time", x: 415, y: 546, width: 32), word("Defrost", x: 415, y: 560, width: 50),
                 word("Express", x: 336, y: 600, width: 40), word("Cook", x: 374, y: 600, width: 26),
                 word("Timer", x: 422, y: 789, width: 34), word("Memory", x: 362, y: 803, width: 42),
                 word("Time", x: 421, y: 829, width: 28), word("Cook", x: 421, y: 841, width: 28),
                 word("START", x: 428, y: 880, width: 44)]
    let label = try #require(KeypadReader.timeCookLabel(in: words, grid: grid))
    #expect(abs(label.centre.x - 421) < 1 && abs(label.centre.y - 835) < 1)
}

@Test("Time and Cook from different keys don't make a label, however close")
func timeCookFromDifferentKeys() {
    #expect(timeCook([word("Time", x: 320, y: 690, width: 40), word("Cook", x: 320, y: 725, width: 40)]) == nil)   // a line too far
    #expect(timeCook([word("Time", x: 260, y: 690, width: 40), word("Cook", x: 320, y: 710, width: 40)]) == nil)   // the next column
    #expect(timeCook([word("Time", x: 260, y: 690, width: 40), word("Cook", x: 320, y: 690, width: 40)]) == nil)   // beside it, a key away
}

private func reading(_ text: String, _ left: Double, _ right: Double, _ top: Double, _ bottom: Double) -> LabelReader.Word {
    LabelReader.Word(text: text, left: left, right: right, top: top, bottom: bottom)
}

@Test("Time on one key and Cook on the next aren't Time Cook, even when one reading of Time runs up to Cook")
func timeCookAcrossTwoKeys() {
    // Frame 06 with Time printed under the 0 and Cook under the Timer, on one line.
    // One reading gave Time a box 51 wide instead of 33, right up to Cook, so the
    // gap between the keys was gone. The rest of the row is close by.
    let grid = KeypadReader.Grid(origin: CGPoint(x: 263, y: 650), columnStep: CGVector(dx: 52, dy: 6),
                                 rowStep: CGVector(dx: 1, dy: 43), read: Set("123456789"))
    let words = [reading("Timer", 352, 382, 782, 797), reading("Power", 254, 283, 798, 813),
                 reading("Time", 301, 334, 812, 829), reading("Time", 301, 352, 812, 832),
                 reading("Cook", 352, 390, 818, 836), reading("Cook", 358, 389, 819, 837),
                 reading("START", 349, 385, 848, 866)]
    #expect(KeypadReader.timeCookLabel(in: words, grid: grid) == nil)
}

@Test("Time on one key over Cook on the key below isn't Time Cook, on a tilted keypad")
func timeCookOnTwoStackedKeys() {
    // A generated panel tilted 20°: Time and Cook are each a key, almost a row apart,
    // but the tilt makes the word boxes tall enough to pass for two lines of one label.
    let grid = KeypadReader.Grid(origin: CGPoint(x: 282, y: 619), columnStep: CGVector(dx: 41.5, dy: -15.2),
                                 rowStep: CGVector(dx: 11.2, dy: 31.2), read: Set("125689"))
    let words = [reading("Memory", 346, 378, 702, 719.5), reading("Power", 308.5, 345, 730, 751),
                 reading("Time", 388.6, 419.1, 686.1, 703.8), reading("Cook", 396, 429.2, 712, 734.5)]
    #expect(KeypadReader.timeCookLabel(in: words, grid: grid) == nil)
}

@Test("Time Defrost and Express Cook aren't Time Cook, on any layout")
func timeCookDecoys() {
    #expect(timeCook(stacked("Time", "Defrost")) == nil)
    #expect(timeCook(line("Time", "Defrost")) == nil)
    #expect(timeCook(line("Express", "Cook")) == nil)
    #expect(timeCook(stacked("Express", "Cook")) == nil)
    // Time right over Express Cook: the Cook is close enough, the Express gives it away.
    #expect(timeCook([word("Time", x: 320, y: 670, width: 40)] + line("Express", "Cook", x: 274, y: 690)) == nil)
    // Time right over Cook, with Defrost beside the Time.
    #expect(timeCook(stacked() + [word("Defrost", x: 366, y: 690, width: 40)]) == nil)
    // A tile edge took Express off one reading, and the next tile read it.
    #expect(timeCook(stacked() + [word("Expres", x: 274, y: 710, width: 40)]) == nil)
}

@Test("a merged label never gives Time Cook")
func timeCookMerged() {
    #expect(timeCook(line("Time", "Defrost", "Express", "Cook", "2", x: 230)) == nil)
    #expect(timeCook(line("Time", "Defrost", x: 300, y: 690) + line("Express", "Cook", "2", x: 300, y: 710)) == nil)
    #expect(timeCook(line("Time", "Cook", "Defrost", x: 280)) == nil)
    #expect(timeCook(stacked() + [word("Defrost", x: 320, y: 730, width: 40)]) == nil)
}

@Test("Cook Time stays what it is, on one line, stacked, or over the next key's Cook")
func cookTimeIsNotTimeCook() {
    #expect(timeCook(stacked("Cook", "Time")) == nil)
    #expect(timeCook(line("Cook", "Time")) == nil)
    // microwave1 prints Cook over Time, then Cook over Power. If the Power isn't read,
    // that Time and the next Cook can still look like a label.
    let column = [word("Cook", x: 320, y: 690, width: 40), word("Time", x: 320, y: 710, width: 40), word("Cook", x: 320, y: 730, width: 40)]
    #expect(timeCook(column) == nil)
    #expect(timeCook(column + [word("Power", x: 320, y: 750, width: 40)]) == nil)
}

@Test("which word comes first is judged along the keypad, so a tilted Cook over Time stays Cook Time")
func cookTimeOnATiltedKeypad() {
    // Tilted about 25°, so a line down also runs left, and word boxes come back tall.
    // By the image alone these two sit on one line with Time first: glare-oven.heif
    // comes back from the scan as Time Cook this way, with Cook Time printed on it.
    let tilted = KeypadReader.Grid(origin: CGPoint(x: 200, y: 500), columnStep: CGVector(dx: 54, dy: 25),
                                   rowStep: CGVector(dx: -21, dy: 46), read: Set("123456789"))
    func tall(_ text: String, x: Double, y: Double) -> LabelReader.Word {
        LabelReader.Word(text: text, left: x - 20, right: x + 20, top: y - 20, bottom: y + 20)
    }
    #expect(KeypadReader.timeCookLabel(in: [tall("Cook", x: 320, y: 700), tall("Time", x: 312, y: 718)], grid: tilted) == nil)
    #expect(KeypadReader.timeCookLabel(in: [tall("Time", x: 320, y: 700), tall("Cook", x: 312, y: 718)], grid: tilted) != nil)
    // Along a tilted line on the key below the 9, Time first and Cook first.
    #expect(KeypadReader.timeCookLabel(in: [tall("Time", x: 210, y: 716), tall("Cook", x: 246, y: 733)], grid: tilted) != nil)
    #expect(KeypadReader.timeCookLabel(in: [tall("Cook", x: 210, y: 716), tall("Time", x: 246, y: 733)], grid: tilted) == nil)
}

@Test("Time Cook with anything printed on it is some other key")
func timeCookWithMore() {
    #expect(timeCook(line("Time", "Cook", "1", x: 280)) == nil)
    #expect(timeCook(stacked() + [word("2", x: 320, y: 730, width: 16)]) == nil)
    #expect(timeCook(stacked() + [word("Power", x: 320, y: 670, width: 40)]) == nil)
    #expect(timeCook(line("Press", "Time", "Cook", "then", x: 240)) == nil)
}

@Test("a tie, Time Cook in two places, is neither")
func timeCookInTwoPlaces() {
    #expect(timeCook(stacked(x: 200) + stacked(x: 320)) == nil)
    #expect(timeCook(stacked(y: 690) + stacked(y: 790)) == nil)
}

@Test("longer words a tile edge can cut down don't count, and neither does a word with more in it")
func timeCookCutWords() {
    #expect(timeCook(stacked("Timer", "Cook")) == nil)
    #expect(timeCook(stacked("Timed", "Cook")) == nil)
    #expect(timeCook(stacked("Time", "Cooking")) == nil)
    #expect(timeCook(stacked("Time/Weight", "Cook")) == nil)
    #expect(timeCook(stacked("Time2", "Cook")) == nil)
    #expect(timeCook(stacked("Tine", "Cook")) == nil)
    #expect(timeCook(stacked("Time", "Book")) == nil)
    // The Time of a Timer that the next tile read whole.
    #expect(timeCook(stacked() + [word("Timer", x: 322, y: 690, width: 48)]) == nil)
    #expect(timeCook(stacked() + [word("Cooking", x: 322, y: 710, width: 60)]) == nil)
}

@Test("a misread of a word on the same spot doesn't take the label away, nor does a stray letter")
func timeCookWithMisreads() {
    // All read off this key on the recorded frames.
    for misread in ["Tirne", "FHre", "Tiame", "EFETA"] {
        #expect(timeCook(stacked() + [word(misread, x: 321, y: 691, width: 40)]) != nil, "\(misread)")
    }
    for misread in ["Coos", "Cooa", "Eock"] {
        #expect(timeCook(stacked() + [word(misread, x: 321, y: 711, width: 40)]) != nil, "\(misread)")
    }
    #expect(timeCook(stacked() + [word("y", x: 280, y: 690, width: 8)]) != nil)
}

@Test("Time Cook above the keypad's first row is the display, as Start is")
func timeCookAboveTheGrid() {
    #expect(timeCook(stacked(y: 200)) == nil)
    #expect(timeCook(stacked(y: 500 - 40)) == nil)
    #expect(timeCook(stacked(y: 500 - 20)) != nil)
    // The whole panel counts, or a word by the display would hide a real one.
    #expect(timeCook(stacked(y: 200) + stacked()) == nil)
}

@Test("the same label read in several tiles gives the middle reading")
func timeCookFromRepeatedReads() throws {
    let reads = stacked(y: 690) + stacked(x: 321, y: 691) + stacked(x: 322, y: 692)
    let label = try #require(timeCook(reads))
    #expect(abs(label.centre.y - 701) < 3)
}

private let timeCookOnPanel = LabelReader.Word(text: "Time Cook", left: 300, right: 340, top: 682, bottom: 718)

@Test("the Time Cook button sits on the words, on the quad, and off the quad there is none")
func timeCookButton() throws {
    let map = KeypadReader.addingTimeCook(on: timeCookOnPanel, to: [], size: frame, panel: .fullFrame)
    let button = try #require(map.first)
    #expect(map.count == 1)
    #expect(button.label == "Time Cook")
    #expect(button.confidence == 0.5)
    #expect(abs(button.bounds.center.x - 320.0 / 720) < 1e-6 && abs(button.bounds.center.y - 700.0 / 1280) < 1e-6)

    let small = PanelQuad(topLeft: ImagePoint(x: 0, y: 0), topRight: ImagePoint(x: 0.2, y: 0),
                          bottomRight: ImagePoint(x: 0.2, y: 0.2), bottomLeft: ImagePoint(x: 0, y: 0.2))
    let kept = [box("Popcorn", x: 0.1, y: 0.1)]
    #expect(KeypadReader.addingTimeCook(on: timeCookOnPanel, to: kept, size: frame, panel: small) == kept)
}

@Test("a box already on the key becomes the button, not a second one beside it")
func timeCookReusesABox() throws {
    let (x, y) = (320.0 / 720, 700.0 / 1280)
    for label in [nil, "Time", "Cook", "TIME"] as [String?] {
        let existing = SurfaceMap.Button(label: label, bounds: PanelRect(x: x - 0.04, y: y - 0.02, width: 0.08, height: 0.04), confidence: 1)
        let map = KeypadReader.addingTimeCook(on: timeCookOnPanel, to: [existing], size: frame, panel: .fullFrame)
        #expect(map.count == 1, "\(label ?? "nil")")
        let button = try #require(map.first)
        #expect(button.label == "Time Cook")
        // It covers the box and the words, and its centre stays on the key.
        #expect(button.bounds.minX <= existing.bounds.minX && button.bounds.maxX >= existing.bounds.maxX)
        #expect(button.bounds.contains(PanelPoint(x: 300.0 / 720, y: 682.0 / 1280)))
        #expect(abs(button.bounds.center.x - x) < 0.01 && abs(button.bounds.center.y - y) < 0.01)
    }
    // Both pieces of the label, each with its own box: one button.
    let pieces = [box("Time", x: x, y: 690.0 / 1280), box("Cook", x: x, y: 710.0 / 1280)]
    #expect(KeypadReader.addingTimeCook(on: timeCookOnPanel, to: pieces, size: frame, panel: .fullFrame).compactMap(\.label) == ["Time Cook"])
}

@Test("nothing else is taken over: other labels on the key, and boxes off it")
func timeCookLeavesOtherBoxes() {
    let (x, y) = (320.0 / 720, 700.0 / 1280)
    let kept = ["9", "Start", "Timer", "Express Cook", "Time Defrost Express Cook 2", "Tirne"].map { box($0, x: x, y: y) }
        + [box(nil, x: 0.1, y: 0.1), box("Time", x: 0.8, y: 0.2)]
    let map = KeypadReader.addingTimeCook(on: timeCookOnPanel, to: kept, size: frame, panel: .fullFrame)
    #expect(map.count == kept.count + 1)
    #expect(kept.allSatisfy(map.contains))
}

@Test("Time Cook already on the map stops the search, and only the real two words do")
func timeCookAlreadyThere() {
    for label in ["Time Cook", "COOK TIME", "Cook Time", "Time COOK", "Time/Cook"] {
        #expect(KeypadReader.hasTimeCook([box(label, x: 0.5, y: 0.5)]), "\(label)")
    }
    for label in [nil, "Time", "Cook", "Express Cook", "Time Defrost", "Time Defrost Express Cook 2", "Time Defrost Express Cook", "Time Cook 2", "Timer rime Cook PART"] as [String?] {
        #expect(!KeypadReader.hasTimeCook([box(label, x: 0.5, y: 0.5)]), "\(label ?? "nil")")
    }
}

@Test("the new button is what a Time Cook request finds, and changes nothing else that's asked for")
func timeCookIsMatched() throws {
    let keys = try panelKeys()
    let others = keys + [box("Start", x: 0.9, y: 0.9), box("Express Cook", x: 0.5, y: 0.02), box("Time Defrost Express Cook", x: 0.9, y: 0.02), box("Timer", x: 0.9, y: 0.5)]
    let quad = PanelQuad.fullFrame
    let map = SurfaceMap(buttons: KeypadReader.addingTimeCook(on: timeCookOnPanel, to: others, size: frame, panel: quad), confidence: 1)

    let found = try #require(TargetMatcher().match("time cook", in: map))
    #expect(found.button.label == "Time Cook" && found.confidence == 1)
    #expect(TargetMatcher().match("time", in: map)?.button.label == "Time Cook")
    #expect(TargetMatcher().match("start", in: map)?.button.label == "Start")
    #expect(TargetMatcher().match("timer", in: map)?.button.label == "Timer")
    #expect(TargetMatcher().match("express cook", in: map)?.button.label == "Express Cook")
    for digit in 0...9 {
        #expect(TargetMatcher().match(String(digit), in: map)?.button.label == String(digit))
    }
}

@Test("a merged label is never the Time Cook target, with or without a real one")
func mergedLabelIsNotTimeCook() {
    // Frame 39 reads this as one label on some runs. Five words already don't count.
    let merged = box("Time Defrost Express Cook", x: 0.5, y: 0.3)
    for request in ["time cook", "time", "cook time"] {
        #expect(TargetMatcher().match(request, in: SurfaceMap(buttons: [merged], confidence: 1)) == nil, "\(request)")
    }
    let map = SurfaceMap(buttons: KeypadReader.addingTimeCook(on: timeCookOnPanel, to: [merged], size: frame, panel: .fullFrame), confidence: 1)
    #expect(TargetMatcher().match("time cook", in: map)?.button.label == "Time Cook")
}

@Test("the Time Cook crop holds the key under the 9, and stays on the image")
func timeCookCrop() throws {
    let crop = try #require(startGrid.timeCookCrop(in: frame).first)
    #expect(crop.contains(CGPoint(x: 300, y: 682)) && crop.contains(CGPoint(x: 340, y: 718)))
    #expect(CGRect(origin: .zero, size: frame).contains(crop))
    // Cut by the bottom of the frame, and then all the way off it.
    let low = KeypadReader.Grid(origin: CGPoint(x: 200, y: 1100), columnStep: CGVector(dx: 60, dy: 0),
                                rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
    #expect(low.timeCookCrop(in: frame).allSatisfy { $0.maxY <= frame.height && !$0.isEmpty })
    let lower = KeypadReader.Grid(origin: CGPoint(x: 200, y: 1150), columnStep: CGVector(dx: 60, dy: 0),
                                  rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
    #expect(lower.timeCookCrop(in: frame).isEmpty)
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

private func blankPhoto(width: Int = 300, height: Int = 300) throws -> PanelPhoto {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return PanelPhoto(data: out as Data, pixelSize: PixelSize(width: width, height: height), timestamp: .distantPast)
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

/// The width and height of each image recognition was handed.
private final class ReadSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [[Int]] = []
    func add(_ image: CGImage) { lock.withLock { sizes.append([image.width, image.height]) } }
    func take() -> [[Int]] { lock.withLock { defer { sizes = [] }; return sizes } }
}

@Test("a world tracking frame's tiles reach Vision at the size a 720x1280 frame's do")
func bigFrameIsReadAtMeasuredSize() async throws {
    let sizes = ReadSizes()
    let reader = KeypadReader(recognizer: { image, _ in
        sizes.add(image)
        return []
    })
    // A 720x1280 frame is read as before: nine tiles of 360x640, each at 3x.
    _ = try await reader.read(in: try blankPhoto(width: 720, height: 1280), panel: .fullFrame, adding: [])
    #expect(sizes.take() == Array(repeating: [1080, 1920], count: 9))

    // Bigger frames, against smaller ones of the same shape with a long side of 1280.
    for (big, small) in [((1440, 1920), (960, 1280)), ((1080, 1920), (720, 1280)), ((1440, 2560), (720, 1280))] {
        _ = try await reader.read(in: try blankPhoto(width: small.0, height: small.1), panel: .fullFrame, adding: [])
        let expected = sizes.take()
        _ = try await reader.read(in: try blankPhoto(width: big.0, height: big.1), panel: .fullFrame, adding: [])
        #expect(sizes.take() == expected, "\(big)")
    }
    #expect(KeypadReader.enlargement(for: CGSize(width: 300, height: 300)) == 1)
    #expect(abs(KeypadReader.enlargement(for: CGSize(width: 1440, height: 1920)) - 2.0 / 3) < 1e-9)
}

// MARK: - Vision

/// False when `.accurate` doesn't run here. It sometimes fails to load on macOS 27,
/// which is a reason to skip, not to fail. Also waits out the slow first load.
private func accurateWorks(on photo: PanelPhoto) async throws -> Bool {
    (try? await LabelReader.recognize(try photo.cgImage(), level: .accurate)) != nil
}

/// A busy machine shouldn't fail these on time. The caps have their own tests.
private let unhurried = KeypadReader(panelLimit: .seconds(60), readLimit: .seconds(60), startLimit: .seconds(20), timeCookLimit: .seconds(20))

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

@Test("keys that only look like Start don't become the Start target",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      .timeLimit(.minutes(5)))
func decoysAreNotStart() async throws {
    let (first, _) = try SyntheticPanel.keypadPhoto(below: "Delay Start", outlined: true)
    guard try await accurateWorks(on: first) else { return }

    // Outlined, each is one label on one key. Printed, Vision reads the first two
    // as two words on one line, so that part is what the scan does without a keypad.
    for (label, outlined) in [("Delay Start", true), ("Time Start", true), ("Start Time", true), ("Smart", true),
                              ("Restart", true), ("Stars", true), ("Smart Cook", true),
                              ("Smart", false), ("Restart", false), ("Stars", false), ("Smart Cook", false)] {
        let (photo, _) = try SyntheticPanel.keypadPhoto(below: label, outlined: outlined)
        let detection = try await scan(unhurried).detectPanel(from: photo)
        #expect(TargetMatcher().match("5", in: detection.map) != nil, "\(label) outlined=\(outlined)")
        #expect(TargetMatcher().match("start", in: detection.map) == nil, "\(label) outlined=\(outlined)")
    }
}

@Test("a Start read in a crop still counts as Delay Start when the tiles read Delay beside it",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func cropCutsOffDelay() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: "Delay Start")
    guard try await accurateWorks(on: photo) else { return }

    // A crop's edge can cut Delay away. Stand in for that: the second crop, which
    // holds the label, reads a bare Start in the same place. The others read nothing.
    let start = try #require(try SyntheticPanel.keypadPhoto().photo.cgImage().cropping(to: CGRect(x: 360, y: 686, width: 180, height: 140)))
    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        switch calls.value {
        case 1...9: return try await LabelReader.recognize(image, level: level)
        case 11: return try await LabelReader.recognize(start, level: level)
        default: return []
        }
    }, panelLimit: .seconds(60), readLimit: .seconds(60), startLimit: .seconds(20))

    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])
    #expect(calls.value == 13)
    #expect(reading.added)
    #expect(TargetMatcher().match("start", in: SurfaceMap(buttons: reading.buttons, confidence: 1)) == nil)
}

@Test("a keypad cut off just below the 0 keeps its ten keys when Start can't be in view",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func keypadAtTheBottomOfTheFrame() async throws {
    // The 0 is at y = 630 and a row is 70 px, so these end 0.3 to 0.9 of a row below it.
    for height in [651, 665, 679, 693] {
        let (photo, keys) = try SyntheticPanel.keypadPhoto(below: nil, height: height)
        guard try await accurateWorks(on: photo) else { return }
        let reading = try await unhurried.read(in: photo, panel: .fullFrame, adding: [])
        #expect(reading.added, "cut at \(height)")
        for (digit, key) in keys {
            let found = try #require(reading.buttons.first { $0.label == String(digit) })
            #expect(found.bounds.contains(PanelPoint(x: key.x, y: key.y)), "\(digit) cut at \(height)")
        }
    }
}

@Test("Start crops that can't be read don't cost the digits",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func failedStartCropsKeepTheDigits() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: nil)
    guard try await accurateWorks(on: photo) else { return }

    // Reads the nine panel tiles, then fails like a crop Vision can't take.
    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        if calls.value > 9 { throw Boom() }
        return try await LabelReader.recognize(image, level: level)
    }, panelLimit: .seconds(60), readLimit: .seconds(60))
    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])

    #expect(calls.value > 9)
    #expect(reading.added)
    #expect(reading.buttons.compactMap(\.label).sorted() == (0...9).map(String.init))
}

@Test("a generated Time Cook gets one button, printed on one line or two, with the digits and Start as they were",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      .timeLimit(.minutes(5)))
func generatedTimeCook() async throws {
    let (first, _) = try SyntheticPanel.keypadPhoto(below: "Time\nCook")
    guard try await accurateWorks(on: first) else { return }

    // Adding to no buttons, so only the keypad reader can have put it there.
    for label in ["Time\nCook", "Time Cook", "TIME\nCOOK"] {
        let (photo, keys) = try SyntheticPanel.keypadPhoto(below: label)
        let reading = try await unhurried.read(in: photo, panel: .fullFrame, adding: [])
        let buttons = reading.buttons.filter { $0.label == "Time Cook" }
        #expect(buttons.count == 1, "\(label)")
        let button = try #require(buttons.first)
        // The label is drawn centred on (450, 760), below the 9.
        #expect(abs(button.bounds.center.x - 450.0 / 720) < 0.02 && abs(button.bounds.center.y - 760.0 / 1280) < 0.02, "\(label)")
        for (digit, key) in keys {
            #expect(reading.buttons.first { $0.label == String(digit) }?.bounds.contains(PanelPoint(x: key.x, y: key.y)) == true, "\(digit)")
        }
    }
}

@Test("keys that only look like Time Cook don't become it",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      .timeLimit(.minutes(5)))
func decoysAreNotTimeCook() async throws {
    let (first, _) = try SyntheticPanel.keypadPhoto(below: "Time\nDefrost")
    guard try await accurateWorks(on: first) else { return }

    for label in ["Time\nDefrost", "Express\nCook", "Express Cook", "Time Defrost", "Cook\nTime", "Cook Time", "Timer\nCook", "Time Cook 2"] {
        let (photo, _) = try SyntheticPanel.keypadPhoto(below: label)
        let reading = try await unhurried.read(in: photo, panel: .fullFrame, adding: [])
        #expect(reading.added, "\(label)")
        #expect(!reading.buttons.contains { $0.label == "Time Cook" }, "\(label)")
    }
}

@Test("a Time Cook crop that's stuck doesn't cost the digits",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func stuckTimeCookCropKeepsTheDigits() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: nil)
    guard try await accurateWorks(on: photo) else { return }

    // Nine panel tiles, three Start crops that read nothing, then the Time Cook crop.
    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        switch calls.value {
        case 1...9: return try await LabelReader.recognize(image, level: level)
        case 13: return try await stuck(image, level)
        default: return []
        }
    }, panelLimit: .seconds(60), readLimit: .seconds(60), timeCookLimit: .milliseconds(100))
    let started = ContinuousClock.now
    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])

    #expect(calls.value == 13)
    #expect(reading.added)
    #expect(reading.buttons.compactMap(\.label).sorted() == (0...9).map(String.init))
    #expect(started.duration(to: .now) < .seconds(15))
}

@Test("Start crops that are stuck don't cost the digits",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func stuckStartCropsKeepTheDigits() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: nil)
    guard try await accurateWorks(on: photo) else { return }

    // Nine panel tiles, then the first Start crop and the box under the 9 never
    // come back. The read has 10 s, so the nine tiles fit on a busy machine.
    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        return calls.value <= 9 ? try await LabelReader.recognize(image, level: level) : try await stuck(image, level)
    }, panelLimit: .seconds(10), readLimit: .seconds(10), startLimit: .milliseconds(100), timeCookLimit: .milliseconds(100))
    let started = ContinuousClock.now
    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])

    #expect(reading.added)
    #expect(reading.buttons.compactMap(\.label).sorted() == (0...9).map(String.init))
    #expect(started.duration(to: .now) < .seconds(10))
}

@Test("no Time Cook crop when the read's cap can't spare it",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func noTimeCookCropWithoutTheTime() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: nil)
    guard try await accurateWorks(on: photo) else { return }

    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        return calls.value <= 9 ? try await LabelReader.recognize(image, level: level) : []
    }, panelLimit: .seconds(60), readLimit: .seconds(60), timeCookLimit: .seconds(31))
    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])

    #expect(calls.value == 12)
    #expect(reading.added)
}

@Test("no Start crops when the read's cap can't spare them, but the box under the 9 is still read",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func noStartCropsWithoutTheTime() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: nil)
    guard try await accurateWorks(on: photo) else { return }

    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        return calls.value <= 9 ? try await LabelReader.recognize(image, level: level) : []
    }, panelLimit: .seconds(60), readLimit: .seconds(60), startLimit: .seconds(31), timeCookLimit: .seconds(20))
    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])

    #expect(calls.value == 10)
    #expect(reading.added)
}

@Test("a Start the Start crops missed counts when the Time Cook crop reads it",
      .enabled(if: TextRecognitionCheck.works, TextRecognitionCheck.skipReason),
      TextRecognitionCheck.timeLimit)
func startInTheTimeCookCrop() async throws {
    let (photo, _) = try SyntheticPanel.keypadPhoto(below: nil)
    guard try await accurateWorks(on: photo) else { return }

    // Nine panel tiles, three Start crops that read nothing, then the Time Cook
    // crop, which reads a Start like the one printed under the 9.
    let start = try #require(try SyntheticPanel.keypadPhoto().photo.cgImage().cropping(to: CGRect(x: 360, y: 686, width: 180, height: 140)))
    let calls = CallCount()
    let reader = KeypadReader(recognizer: { image, level in
        calls.add()
        switch calls.value {
        case 1...9: return try await LabelReader.recognize(image, level: level)
        case 13: return try await LabelReader.recognize(start, level: level)
        default: return []
        }
    }, panelLimit: .seconds(60), readLimit: .seconds(60), timeCookLimit: .seconds(20))
    let reading = try await reader.read(in: photo, panel: .fullFrame, adding: [])

    #expect(calls.value == 13)
    #expect(reading.added)
    let found = try #require(TargetMatcher().match("start", in: SurfaceMap(buttons: reading.buttons, confidence: 1))?.button)
    // Under the 9 (450, 560) and below Timer (450, 630).
    #expect(abs(found.bounds.center.x - 450.0 / 720) < 0.05)
    #expect(found.bounds.center.y > 630.0 / 1280 && found.bounds.center.y < 780.0 / 1280)
    #expect(!reading.buttons.contains { $0.label == "Time Cook" })
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

// MARK: - Number keys on a map

@Suite("Number keys on a map")
struct NumberKeysTests {

    private func map(_ labels: String?...) -> SurfaceMap {
        SurfaceMap(buttons: labels.map { SurfaceMap.Button(label: $0, bounds: PanelRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 1) },
                   confidence: 1)
    }

    @Test("One digit key is enough", arguments: "0123456789")
    func digit(_ digit: Character) {
        #expect(map("Start", nil, String(digit)).hasNumberKeys)
    }

    @Test("Other labels with numbers in them aren't number keys",
          arguments: ["Start", "", "10", "30 Sec", "Add 30", "+30", "1:35", "0:00", "1 2 3", "٣", "½"])
    func notADigitKey(_ label: String) {
        #expect(!map(label).hasNumberKeys)
    }

    @Test("Unread buttons and an empty map have no number keys")
    func nothingToFind() {
        #expect(!map(nil, nil).hasNumberKeys)
        #expect(!SurfaceMap.empty.hasNumberKeys)
    }

    @Test("A keypad the reader placed counts")
    func placedKeypad() throws {
        let grid = KeypadReader.Grid(origin: CGPoint(x: 200, y: 500), columnStep: CGVector(dx: 60, dy: 0),
                                     rowStep: CGVector(dx: 0, dy: 50), read: Set("123456789"))
        let keys = try #require(KeypadReader.keyButtons(of: grid, size: CGSize(width: 720, height: 1280), panel: .fullFrame))
        #expect(SurfaceMap(buttons: keys, confidence: 1).hasNumberKeys)
    }
}
