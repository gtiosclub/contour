//
//  KeypadReader.swift
//  SurfaceUnderstanding — Surface / Labels
//
//  Puts all ten digit keys on the map, so a cook time can be typed.
//
//  Vision reads the small digits on a real camera frame badly: on 63 recorded
//  frames it never read the 0 and rarely the 1 or 3. Read again in overlapping
//  tiles at 3x it finds more of them, but still not all. A keypad is a grid,
//  though, so the digits it did read place the ones it didn't.
//
//  A WRONG KEY IS WORSE THAN NO KEY, so the grid has to earn its place: the read
//  digits sit on it closely, in all three rows, and it has the shape of a keypad.
//  Anything else leaves the map exactly as it was.
//
//  Words and grids here are in pixels of the upright image, until the buttons
//  are built. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import CoreGraphics
import Foundation
import Vision

/// Finds a phone-style 1-2-3 keypad on the photo and adds its keys to the buttons.
struct KeypadReader: Sendable {

    var recognizer: LabelReader.Recognizer = LabelReader.recognize
    /// How long the panel tiles and the whole read may take before the answer is dropped.
    var panelLimit: Duration = .seconds(2)
    var readLimit: Duration = .seconds(4)

    /// A cap ran out, so the answer is no longer wanted.
    struct TimedOut: Error {}

    /// The buttons to use, and what happened on the way, for the log.
    struct Reading {
        var buttons: [SurfaceMap.Button]
        var digitsRead: Int
        var stage: Int
        /// A keypad fitted the digits.
        var fit: Bool
        /// Its keys are on the map. A keypad off the quad leaves them out.
        var added: Bool
    }

    /// `buttons` with the keypad merged in, or unchanged if no keypad fits.
    ///
    /// Reads the panel first. If that found digits but no keypad, the keypad may
    /// be small or outside the panel, so it pools a read of the whole frame. No
    /// digits at all means there's no keypad to help, so it stops.
    ///
    /// - Throws: `TimedOut`, `CancellationError`, or whatever recognition throws.
    func read(in photo: PanelPhoto, panel: PanelQuad, adding buttons: [SurfaceMap.Button]) async throws -> Reading {
        try await Self.within(readLimit) {
            let image = try photo.cgImage()
            let size = CGSize(width: image.width, height: image.height)

            let panelTiles = Self.tiles(of: Self.box(of: panel, in: size), across: 3, fraction: 0.5)
            var words = try await Self.within(self.panelLimit) {
                try await self.words(in: image, tiles: panelTiles, scale: 3)
            }
            var stage = 1
            var grid = Self.keypad(in: words, size: size)
            if grid == nil, !Self.digits(in: words).isEmpty {
                let frame = CGRect(origin: .zero, size: size)
                words += try await self.words(in: image, tiles: Self.tiles(of: frame, across: 5, fraction: 0.333), scale: 3)
                stage = 2
                grid = Self.keypad(in: words, size: size)
            }
            let digitsRead = Self.digits(in: words).count

            guard let grid, let keys = Self.keyButtons(of: grid, size: size, panel: panel) else {
                return Reading(buttons: buttons, digitsRead: digitsRead, stage: stage, fit: grid != nil, added: false)
            }
            var merged = Self.merging(keys, into: buttons)
            if TargetMatcher().match("start", in: SurfaceMap(buttons: merged, confidence: 1)) == nil {
                var start = Self.startWord(in: words, grid: grid)
                if start == nil {
                    // Start is extra: crops that can't be read don't cost the digits.
                    let crops = (try? await self.words(in: image, tiles: grid.startCrops(in: size), scale: 2)) ?? []
                    start = Self.startWord(in: words + crops, grid: grid)
                }
                if let start {
                    merged += Self.startButton(on: start, size: size, panel: panel)
                }
            }
            return Reading(buttons: merged, digitsRead: digitsRead, stage: stage, fit: true, added: true)
        }
    }

    // MARK: - Reading

    /// `count` × `count` overlapping tiles of `box`, each `fraction` of its size.
    static func tiles(of box: CGRect, across count: Int, fraction: Double) -> [CGRect] {
        let step = (1 - fraction) / Double(count - 1)
        return (0..<count).flatMap { column in
            (0..<count).map { row in
                CGRect(x: box.minX + box.width * Double(column) * step, y: box.minY + box.height * Double(row) * step,
                       width: box.width * fraction, height: box.height * fraction).integral
            }
        }
    }

    /// The upright box around `quad`, kept on the image.
    static func box(of quad: PanelQuad, in size: CGSize) -> CGRect {
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        let left = max(0, corners.map(\.x).min()!), right = min(1, corners.map(\.x).max()!)
        let top = max(0, corners.map(\.y).min()!), bottom = min(1, corners.map(\.y).max()!)
        return CGRect(x: left * size.width, y: top * size.height,
                      width: (right - left) * size.width, height: (bottom - top) * size.height)
    }

    /// Every word in `tiles`, each tile enlarged by `scale` first. `.accurate` only:
    /// `.fast` found no keypad at all on the recorded frames.
    private func words(in image: CGImage, tiles: [CGRect], scale: Double) async throws -> [LabelReader.Word] {
        var words: [LabelReader.Word] = []
        for tile in tiles {
            try Task.checkCancellation()
            let observations = try await recognizer(try Self.enlarged(image, tile: tile, by: scale), .accurate)
            words += LabelReader().locateWords(in: observations, panel: .fullFrame).map { word in
                LabelReader.Word(text: word.text,
                                 left: tile.minX + word.left * tile.width, right: tile.minX + word.right * tile.width,
                                 top: tile.minY + word.top * tile.height, bottom: tile.minY + word.bottom * tile.height)
            }
        }
        return words
    }

    private static func enlarged(_ image: CGImage, tile: CGRect, by scale: Double) throws -> CGImage {
        guard
            let cropped = image.cropping(to: tile),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(Double(cropped.width) * scale), height: Int(Double(cropped.height) * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw SurfaceUnderstandingError.underlying("Couldn't enlarge keypad tile \(tile)")
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let enlarged = context.makeImage() else {
            throw SurfaceUnderstandingError.underlying("Couldn't enlarge keypad tile \(tile)")
        }
        return enlarged
    }

    /// `work`'s answer, or `TimedOut` once `limit` has passed.
    ///
    /// Not a task group, because a group waits for its children and Vision doesn't
    /// always stop when cancelled: while its model was loading, a call cancelled at
    /// 2 s came back after 6.3 s. Here the caller moves on, and the work stops at
    /// its next check once Vision hands it back.
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let (answers, answer) = AsyncStream.makeStream(of: Result<T, any Error>.self)
        let worker = Task {
            do { answer.yield(.success(try await work())) } catch { answer.yield(.failure(error)) }
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            answer.yield(.failure(TimedOut()))
        }
        defer {
            worker.cancel()
            timer.cancel()
        }
        for await first in answers { return try first.get() }
        // The stream only ends without an answer when the caller is cancelled.
        throw CancellationError()
    }

    // MARK: - Fitting the grid

    /// Column and row of each digit on a phone-style keypad. The 0 is under the 8.
    static let layout: [Character: (column: CGFloat, row: CGFloat)] = [
        "1": (0, 0), "2": (1, 0), "3": (2, 0),
        "4": (0, 1), "5": (1, 1), "6": (2, 1),
        "7": (0, 2), "8": (1, 2), "9": (2, 2),
        "0": (1, 3),
    ]

    /// The centres of a keypad's keys, from the digits that were read.
    struct Grid: Equatable {
        /// The centre of the 1 key.
        var origin: CGPoint
        /// From a key to the next one along its row.
        var columnStep: CGVector
        /// From a key to the next one down its column.
        var rowStep: CGVector
        /// The digits the grid was fitted to. The rest are filled in.
        var read: Set<Character>

        func point(column: CGFloat, row: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + columnStep.dx * column + rowStep.dx * row,
                    y: origin.y + columnStep.dy * column + rowStep.dy * row)
        }

        func centre(of digit: Character) -> CGPoint {
            point(column: layout[digit]!.column, row: layout[digit]!.row)
        }

        /// Which row `point` is on, as a fraction: 0 is the 1-2-3 row, 3 the 0 key's.
        func row(of point: CGPoint) -> CGFloat {
            let determinant = columnStep.dx * rowStep.dy - rowStep.dx * columnStep.dy
            return (columnStep.dx * (point.y - origin.y) - columnStep.dy * (point.x - origin.x)) / determinant
        }

        /// Does this look like a keypad? Digits read in all three rows, columns
        /// running right, rows running down, roughly square corners, no more than
        /// 30° of tilt, and every key on the frame.
        func isKeypad(in size: CGSize) -> Bool {
            let columnLength = hypot(columnStep.dx, columnStep.dy), rowLength = hypot(rowStep.dx, rowStep.dy)
            let cosine = (columnStep.dx * rowStep.dx + columnStep.dy * rowStep.dy) / (columnLength * rowLength)
            return Set(read.map { layout[$0]!.row }).isSuperset(of: [0, 1, 2])
                && columnStep.dx > 0 && rowStep.dy > 0
                && (0.3...1.5).contains(rowLength / columnLength)
                && abs(cosine) <= 0.5
                && abs(atan2(columnStep.dy, columnStep.dx)) <= .pi / 6
                && layout.keys.allSatisfy { digit in
                    let key = centre(of: digit)
                    return (-0.02...1.02).contains(key.x / size.width) && (-0.02...1.02).contains(key.y / size.height)
                }
        }

        /// Three boxes below the keypad where Start tends to be printed: one wide
        /// and one to each side. A keypad at the bottom of the frame has fewer, or none.
        func startCrops(in size: CGSize) -> [CGRect] {
            let cellWidth = hypot(columnStep.dx, columnStep.dy), cellHeight = hypot(rowStep.dx, rowStep.dy)
            return [(column: 1, cells: (4, 2.4)), (column: 2, cells: (2, 2)), (column: 0, cells: (2, 2))].map { (crop: (column: CGFloat, cells: (CGFloat, CGFloat))) in
                let centre = point(column: crop.column, row: 4.8)
                let width = crop.cells.0 * cellWidth, height = crop.cells.1 * cellHeight
                return CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
                    .intersection(CGRect(origin: .zero, size: size)).integral
            }.filter { !$0.isEmpty }
        }
    }

    /// The keypad in `words`, if they make one.
    static func keypad(in words: [LabelReader.Word], size: CGSize) -> Grid? {
        guard let grid = fit(digits(in: words)), grid.isKeypad(in: size) else { return nil }
        return grid
    }

    /// Where each digit was read: the median across its readings, since the tiles
    /// overlap. Only a word that is one digit counts.
    static func digits(in words: [LabelReader.Word]) -> [Character: CGPoint] {
        var read: [Character: [CGPoint]] = [:]
        for word in words where word.text.count == 1 {
            let digit = Character(word.text)
            if layout[digit] != nil {
                read[digit, default: []].append(CGPoint(x: word.centre.x, y: word.centre.y))
            }
        }
        return read.mapValues { CGPoint(x: median($0.map(\.x)), y: median($0.map(\.y))) }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The grid through `read`. While any digit is more than 0.15 of a cell off it,
    /// on each axis's own step, drops the worst one and fits again. Needs five.
    static func fit(_ read: [Character: CGPoint]) -> Grid? {
        var read = read
        while read.count >= 5 {
            let x = plane(through: read.mapValues(\.x)), y = plane(through: read.mapValues(\.y))
            let grid = Grid(origin: CGPoint(x: x[0], y: y[0]),
                            columnStep: CGVector(dx: x[1], dy: y[1]), rowStep: CGVector(dx: x[2], dy: y[2]),
                            read: Set(read.keys))

            let columnLength = hypot(grid.columnStep.dx, grid.columnStep.dy)
            let rowLength = hypot(grid.rowStep.dx, grid.rowStep.dy)
            let errors = read.map { digit, point in
                let key = grid.centre(of: digit)
                return (digit: digit, cells: hypot((point.x - key.x) / columnLength, (point.y - key.y) / rowLength))
            }
            let worst = errors.max { $0.cells < $1.cells }!
            if worst.cells <= 0.15 { return grid }
            read[worst.digit] = nil
        }
        return nil
    }

    /// The least-squares `[a, b, c]` for `a + b·column + c·row ≈ value`. Five or
    /// more keypad positions never lie on one line, so the system always solves.
    private static func plane(through values: [Character: CGFloat]) -> [CGFloat] {
        var system = Array(repeating: [CGFloat](repeating: 0, count: 4), count: 3)
        for (digit, value) in values {
            let terms: [CGFloat] = [1, layout[digit]!.column, layout[digit]!.row]
            for i in 0..<3 {
                system[i][3] += terms[i] * value
                for j in 0..<3 { system[i][j] += terms[i] * terms[j] }
            }
        }
        for column in 0..<3 {
            let pivot = (column..<3).max { abs(system[$0][column]) < abs(system[$1][column]) }!
            system.swapAt(column, pivot)
            for row in 0..<3 where row != column {
                let factor = system[row][column] / system[column][column]
                for j in 0..<4 { system[row][j] -= factor * system[column][j] }
            }
        }
        return (0..<3).map { system[$0][3] / system[$0][$0] }
    }

    // MARK: - Building the buttons

    /// One button per digit, on the quad the map is normalized against, or `nil`
    /// if any key's centre is off it: then the quad is wrong for this keypad, and
    /// guiding to the keys it does hold would mean trusting that wrong quad.
    ///
    /// A digit that was read gets the same confidence as any printed label. One
    /// the grid filled in is less sure than that.
    static func keyButtons(of grid: Grid, size: CGSize, panel: PanelQuad) -> [SurfaceMap.Button]? {
        func onPanel(_ point: CGPoint) -> PanelPoint {
            PanelDetector().rectify(ImagePoint(x: point.x / size.width, y: point.y / size.height), within: panel)
        }
        var keys: [SurfaceMap.Button] = []
        for digit in layout.keys.sorted() {
            let key = grid.centre(of: digit)
            let centre = onPanel(key)
            guard (-0.05...1.05).contains(centre.x), (-0.05...1.05).contains(centre.y) else { return nil }

            // A cell is one step wide and one step tall, centred on the key, so
            // `bounds.center` stays the point the grid says the key is. A quad can
            // come back turned a quarter, so a row of keys may run down the panel.
            func step(_ step: CGVector) -> PanelVector {
                onPanel(CGPoint(x: key.x - step.dx / 2, y: key.y - step.dy / 2))
                    .vector(to: onPanel(CGPoint(x: key.x + step.dx / 2, y: key.y + step.dy / 2)))
            }
            let along = step(grid.columnStep), down = step(grid.rowStep)
            let upright = abs(along.dx * down.dy) >= abs(along.dy * down.dx)
            let width = abs(upright ? along.dx : down.dx), height = abs(upright ? down.dy : along.dy)
            keys.append(SurfaceMap.Button(
                label: String(digit),
                bounds: PanelRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height),
                confidence: grid.read.contains(digit) ? 0.5 : 0.3
            ))
        }
        return keys
    }

    /// `keys` take over from what the scan found for them.
    ///
    /// Any digit label goes, since the grid replaces it. In a key's cell, so does an
    /// unlabelled box, which is that key seen again; a misread of the digit, which
    /// has no word in it; and Start, which a box there took from the key below it.
    /// Any other word stays: Memory under the 0 is printed on that key.
    static func merging(_ keys: [SurfaceMap.Button], into buttons: [SurfaceMap.Button]) -> [SurfaceMap.Button] {
        buttons.filter { button in
            if let label = button.label, label.count == 1, layout[Character(label)] != nil { return false }
            guard keys.contains(where: { $0.bounds.contains(button.bounds.center) }) else { return true }
            guard let label = button.label?.lowercased() else { return false }
            return label.filter(\.isLetter).count >= 2 && !label.contains("start")
        } + keys
    }

    // MARK: - Start

    /// The word Start, or failing that a word one edit away from it, at or below the
    /// keypad's first row. Above that it's the display, which can say Start under
    /// the clock. The tiles overlap, so the same word can come back several times.
    ///
    /// The button gets the bare label Start, so TargetMatcher can't see what was
    /// printed with it, and its rule has to hold here: Start never means Delay Start
    /// or Time Start. Other real words don't count either, nor what a tile edge cuts
    /// them down to: Restart to start, Stars to Star, the Start of Delay Start to tart.
    static func startWord(in words: [LabelReader.Word], grid: Grid) -> LabelReader.Word? {
        let others = words.filter { word in
            word.text.lowercased().split { !$0.isLetter }.contains { part in
                ["smart", "stars", "stat"].contains(String(part))
                    || ["delay", "time", "restart"].contains { editDistance(String(part), $0) <= 1 }
            }
        }
        let inReach = words.filter { word in
            grid.row(of: CGPoint(x: word.centre.x, y: word.centre.y)) >= -0.5
                && !others.contains { other in
                    // Close beside it on the line, or on the line above or below it.
                    abs(other.centre.y - word.centre.y) < 2 * word.height
                        && max(other.left - word.right, word.left - other.right) < 2 * word.height
                }
        }
        var found = inReach.filter { $0.text.lowercased().hasPrefix("start") }
        if found.isEmpty {
            found = inReach.filter { word in
                word.text.count >= 4 && word.text.allSatisfy(\.isLetter)
                    && editDistance(word.text.lowercased(), "start") <= 1
            }
        }
        guard !found.isEmpty else { return nil }
        return found.sorted { $0.centre.y < $1.centre.y }[found.count / 2]
    }

    /// A Start button on `word`, under the same rules as any printed label.
    static func startButton(on word: LabelReader.Word, size: CGSize, panel: PanelQuad) -> [SurfaceMap.Button] {
        let corners = [(word.left, word.top), (word.right, word.top), (word.left, word.bottom), (word.right, word.bottom)]
            .map { PanelDetector().rectify(ImagePoint(x: $0.0 / size.width, y: $0.1 / size.height), within: panel) }
        let left = corners.map(\.x).min() ?? .nan, right = corners.map(\.x).max() ?? .nan
        let top = corners.map(\.y).min() ?? .nan, bottom = corners.map(\.y).max() ?? .nan
        return LiveSurfaceUnderstanding.printedButtons(from: [
            (label: "Start", bounds: PanelRect(x: left, y: top, width: right - left, height: bottom - top))
        ])
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in a.indices {
            var diagonal = row[0]
            row[0] = i + 1
            for j in b.indices {
                let above = row[j + 1]
                row[j + 1] = a[i] == b[j] ? diagonal : min(diagonal, above, row[j]) + 1
                diagonal = above
            }
        }
        return row[b.count]
    }
}
