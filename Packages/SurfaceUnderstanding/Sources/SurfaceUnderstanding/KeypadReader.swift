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
//  Start and Time Cook get the same treatment once there's a keypad to measure
//  from, since a cook time isn't typed without them.
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
    /// How long the three Start crops, and then the box under the 9, may take.
    /// They're extra, so they can't cost the rest.
    var startLimit: Duration = .seconds(1)
    var timeCookLimit: Duration = .milliseconds(300)

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
    /// digits at all means there's no keypad to help, so it stops. With a keypad,
    /// it also looks for Start and Time Cook, the keys a typed cook time needs.
    ///
    /// - Throws: `TimedOut`, `CancellationError`, or whatever recognition throws.
    func read(in photo: PanelPhoto, panel: PanelQuad, adding buttons: [SurfaceMap.Button]) async throws -> Reading {
        try await Self.within(readLimit) {
            let started = ContinuousClock.now
            let image = try photo.cgImage()
            let size = CGSize(width: image.width, height: image.height)
            let enlargement = Self.enlargement(for: size)

            let panelTiles = Self.tiles(of: Self.box(of: panel, in: size), across: 3, fraction: 0.5)
            var words = try await Self.within(self.panelLimit) {
                try await self.words(in: image, tiles: panelTiles, scale: 3 * enlargement)
            }
            var stage = 1
            var grid = Self.keypad(in: words, size: size)
            if grid == nil, !Self.digits(in: words).isEmpty {
                let frame = CGRect(origin: .zero, size: size)
                words += try await self.words(in: image, tiles: Self.tiles(of: frame, across: 5, fraction: 0.333), scale: 3 * enlargement)
                stage = 2
                grid = Self.keypad(in: words, size: size)
            }
            let digitsRead = Self.digits(in: words).count

            guard let grid, let keys = Self.keyButtons(of: grid, size: size, panel: panel) else {
                return Reading(buttons: buttons, digitsRead: digitsRead, stage: stage, fit: grid != nil, added: false)
            }
            var merged = Self.merging(keys, into: buttons)
            let needsStart = TargetMatcher().match("start", in: SurfaceMap(buttons: merged, confidence: 1)) == nil
            let needsTimeCook = !Self.hasTimeCook(merged)
            // Start and Time Cook are extra: crops that can't be read in their own time
            // don't cost the digits, and each is only read if the read's cap can spare
            // that time twice over. Their caps race the read's, and a timer can fire
            // late: a Start cap due 0.1 s before the read's lost to it in a test.
            if needsStart, Self.startWord(in: words, grid: grid) == nil,
               self.readLimit - started.duration(to: .now) > self.startLimit * 2 {
                words += await self.extraWords(in: image, tiles: grid.startCrops(in: size), scale: 2 * enlargement,
                                               within: self.startLimit)
            }
            // The box under the 9, for either key.
            if needsTimeCook && Self.timeCookLabel(in: words, grid: grid) == nil
                || needsStart && Self.startWord(in: words, grid: grid) == nil,
               self.readLimit - started.duration(to: .now) > self.timeCookLimit * 2 {
                words += await self.extraWords(in: image, tiles: grid.timeCookCrop(in: size), scale: 2 * enlargement,
                                               within: self.timeCookLimit)
            }
            if needsStart, let start = Self.startWord(in: words, grid: grid) {
                merged += Self.startButton(on: start, size: size, panel: panel)
            }
            if needsTimeCook, let label = Self.timeCookLabel(in: words, grid: grid) {
                merged = Self.addingTimeCook(on: label, to: merged, size: size, panel: panel)
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

    /// How much of the usual enlargement a frame of `size` gets. The tiles and crops
    /// were measured on 720x1280 frames. The world tracking camera's are about
    /// 1440x1920 with about the same view along the long side, so a key there is 1.5
    /// times the pixels. Enlarged 2/3 as much, each tile reaches Vision at the size
    /// it did on the measured frames, sharper, and costs about the same time. On
    /// those frames scaled up 1.5 times and read at full enlargement, a read took
    /// 0.92 s instead of 0.67 s, and the slowest ran out of time.
    static func enlargement(for size: CGSize) -> Double {
        min(1, 1280 / max(size.width, size.height))
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

    /// The words in `tiles`, or none if they can't be read within `limit`.
    private func extraWords(in image: CGImage, tiles: [CGRect], scale: Double, within limit: Duration) async -> [LabelReader.Word] {
        (try? await Self.within(limit) { try await self.words(in: image, tiles: tiles, scale: scale) }) ?? []
    }

    private static func enlarged(_ image: CGImage, tile: CGRect, by scale: Double) throws -> CGImage {
        guard
            let cropped = image.cropping(to: tile),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int((Double(cropped.width) * scale).rounded()), height: Int((Double(cropped.height) * scale).rounded()),
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

        /// Which column `point` is in, as a fraction: 0 is the 1-4-7 column.
        func column(of point: CGPoint) -> CGFloat {
            let determinant = columnStep.dx * rowStep.dy - rowStep.dx * columnStep.dy
            return (rowStep.dy * (point.x - origin.x) - rowStep.dx * (point.y - origin.y)) / determinant
        }

        /// Whether `a` is printed before `b`: on the line above it, or to its left on
        /// the same line. Judged along the keypad, since a tilt can swap them in the image.
        func reads(_ a: CGPoint, before b: CGPoint) -> Bool {
            let down = (row(of: b) - row(of: a)) * hypot(rowStep.dx, rowStep.dy)
            let along = (column(of: b) - column(of: a)) * hypot(columnStep.dx, columnStep.dy)
            return abs(down) >= abs(along) ? down > 0 : along > 0
        }

        /// Whether `a` and `b` are in one key's cell, as the middles of one label's
        /// words are: the same column, and less than half a row apart. Rows are judged
        /// by the gap, since the keys below the digits needn't sit on whole rows.
        func inOneCell(_ a: CGPoint, _ b: CGPoint) -> Bool {
            column(of: a).rounded() == column(of: b).rounded() && abs(row(of: a) - row(of: b)) < 0.5
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

        /// The box under the 9 where the one microwave we have frames of prints Time
        /// Cook, and where many keypads have Start. Read for either key. Elsewhere it
        /// reads nothing useful, and that only costs the one read.
        func timeCookCrop(in size: CGSize) -> [CGRect] {
            let centre = point(column: 2, row: 3.9)
            let width = 2.2 * hypot(columnStep.dx, columnStep.dy), height = 1.8 * hypot(rowStep.dx, rowStep.dy)
            let crop = CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
                .intersection(CGRect(origin: .zero, size: size)).integral
            return crop.isEmpty ? [] : [crop]
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
            let text = word.text.lowercased()
            return (text.split { !$0.isLetter }.map(String.init) + [text.filter(\.isLetter)]).contains { part in
                ["smart", "stars", "stat"].contains(part)
                    || ["delay", "time", "restart"].contains { editDistance(part, $0) <= 1 }
            }
        }
        let inReach = words.filter { word in
            grid.row(of: CGPoint(x: word.centre.x, y: word.centre.y)) >= -0.5
                && !others.contains { other in
                    // Close beside it on the line, or on the line above or below it.
                    abs(other.centre.y - word.centre.y) < 2 * max(word.height, other.height)
                        && max(other.left - word.right, word.left - other.right) < 2 * max(word.height, other.height)
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
        LiveSurfaceUnderstanding.printedButtons(from: [(label: "Start", bounds: bounds(of: word, size: size, panel: panel))])
    }

    /// `word`'s box on the quad.
    private static func bounds(of word: LabelReader.Word, size: CGSize, panel: PanelQuad) -> PanelRect {
        let corners = [(word.left, word.top), (word.right, word.top), (word.left, word.bottom), (word.right, word.bottom)]
            .map { PanelDetector().rectify(ImagePoint(x: $0.0 / size.width, y: $0.1 / size.height), within: panel) }
        let left = corners.map(\.x).min() ?? .nan, right = corners.map(\.x).max() ?? .nan
        let top = corners.map(\.y).min() ?? .nan, bottom = corners.map(\.y).max() ?? .nan
        return PanelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: - Time Cook

    /// The two words on a label, in any order, are already on the map as one button.
    /// A printed Cook Time counts: it's that key, and it keeps the name it has.
    static func hasTimeCook(_ buttons: [SurfaceMap.Button]) -> Bool {
        buttons.contains { button in
            let words = (button.label ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return words.count == 2 && Set(words) == ["time", "cook"]
        }
    }

    /// The box around Time and Cook, printed together as one key and nothing else,
    /// at or below the keypad's first row. Nil if there's any doubt, because the
    /// button gets the bare label Time Cook and nobody can see what was printed:
    ///
    /// - Two words that just happen to be close have to pass the rule LabelReader
    ///   uses for the lines of one label, and sit in one key's cell. Time on one key
    ///   and Cook on the next, beside it or below it, isn't a label, even when one
    ///   reading of Time runs its box right up to the Cook.
    /// - Another word on it makes it another key: Time Defrost, Express Cook, Cook
    ///   Power, Time Cook 2. So does a longer word that a tile edge cut down: Timer.
    /// - Cook before Time is printed Cook Time. On an oven that's another kind of key:
    ///   it sets how long a bake runs and starts nothing. It keeps its printed name.
    /// - The pair in two places is a tie, so it's neither.
    static func timeCookLabel(in words: [LabelReader.Word], grid: Grid) -> LabelReader.Word? {
        let cooks = words.filter { printedText($0) == "cook" }
        let pairs = words.filter { printedText($0) == "time" }.flatMap { time in
            cooks.filter { LabelReader.belongTogether(time, $0) }.map { (time: time, cook: $0) }
        }
        guard !pairs.isEmpty else { return nil }

        let labels = pairs.map { pair in
            LabelReader.Word(text: "Time Cook",
                             left: min(pair.time.left, pair.cook.left), right: max(pair.time.right, pair.cook.right),
                             top: min(pair.time.top, pair.cook.top), bottom: max(pair.time.bottom, pair.cook.bottom))
        }
        let places = labels.map { CGPoint(x: $0.centre.x, y: $0.centre.y) }
        let inOnePlace = places.allSatisfy { place in
            abs(grid.row(of: place) - grid.row(of: places[0])) <= 0.5
                && abs(grid.column(of: place) - grid.column(of: places[0])) <= 0.5
        }
        guard inOnePlace,
              places.allSatisfy({ grid.row(of: $0) >= -0.5 }),
              pairs.allSatisfy({ grid.inOneCell(CGPoint(x: $0.time.centre.x, y: $0.time.centre.y), CGPoint(x: $0.cook.centre.x, y: $0.cook.centre.y)) }),
              pairs.allSatisfy({ grid.reads(CGPoint(x: $0.time.centre.x, y: $0.time.centre.y), before: CGPoint(x: $0.cook.centre.x, y: $0.cook.centre.y)) }),
              !words.contains(where: { word in pairs.contains { isAnotherWord(word, on: $0.time, $0.cook) } })
        else { return nil }
        return labels.sorted { $0.centre.y < $1.centre.y }[labels.count / 2]
    }

    /// Whether `word` is printed with `time` and `cook`, as more than a second reading of them.
    private static func isAnotherWord(_ word: LabelReader.Word, on time: LabelReader.Word, _ cook: LabelReader.Word) -> Bool {
        let text = printedText(word)
        guard text != "time", text != "cook",
              word.text.contains(where: \.isNumber) || word.text.filter(\.isLetter).count >= 2 else { return false }
        let onTop = [time, cook].contains { printed in
            printed.left <= word.centre.x && word.centre.x <= printed.right
                && printed.top <= word.centre.y && word.centre.y <= printed.bottom
        }
        if onTop { return text.contains("time") || text.contains("cook") }
        return LabelReader.belongTogether(word, time) || LabelReader.belongTogether(word, cook)
    }

    /// What a word says, without case or the punctuation around it.
    private static func printedText(_ word: LabelReader.Word) -> String {
        word.text.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    /// `buttons` with a Time Cook button on `label`, under the same rules as any
    /// printed label. A box already centred on those words is that key seen again,
    /// so it becomes this button instead of a second one beside it. That's a box
    /// with no label, or with only Time or Cook. Anything else on it stays.
    static func addingTimeCook(on label: LabelReader.Word, to buttons: [SurfaceMap.Button], size: CGSize, panel: PanelQuad) -> [SurfaceMap.Button] {
        let printed = bounds(of: label, size: size, panel: panel)
        let same = buttons.filter { button in
            guard printed.contains(button.bounds.center) else { return false }
            guard let text = button.label?.lowercased() else { return true }
            return ["time", "cook"].contains(text)
        }
        var area = printed
        for button in same {
            let left = min(area.minX, button.bounds.minX), right = max(area.maxX, button.bounds.maxX)
            let top = min(area.minY, button.bounds.minY), bottom = max(area.maxY, button.bounds.maxY)
            area = PanelRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        let added = LiveSurfaceUnderstanding.printedButtons(from: [(label: "Time Cook", bounds: area)])
        return added.isEmpty ? buttons : buttons.filter { !same.contains($0) } + added
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

extension SurfaceMap {

    /// Is any button labelled with one digit? `false` means nothing on this map can
    /// type a number, either because the panel has no number keys or because the
    /// scan missed them. The map can't say which.
    public var hasNumberKeys: Bool {
        buttons.contains { button in
            guard let label = button.label, label.count == 1 else { return false }
            return KeypadReader.layout[Character(label)] != nil
        }
    }
}
