//
//  PanelDetector.swift
//  SurfaceUnderstanding — Surface / Panel Detector
//
//  Weeks 2–3 deliverable: "Detect an appliance interface in a photo."
//
//  Stage 1 of three. Find the panel in the image and work out how to rectify it
//  to the unit square that everything downstream is expressed in. Get this
//  wrong and every button position is wrong by the same amount.
//
//  COORDINATES: what you return defines panel space for the whole app —
//  (0,0) top-left, (1,1) bottom-right, y DOWNWARD.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision

/// Stage 1 — find the panel.
public struct PanelDetector: Sendable {

    /// Opt in to OCR-based control expansion; disabled for the low-latency MVP.
    public var expandWithText: Bool

    public init(expandWithText: Bool = false) {
        self.expandWithText = expandWithText
    }

    /// Locate the appliance panel in `photo`.
    ///
    /// - Returns: the panel's corners and how sure we are it is a panel.
    /// - Throws: `SurfaceUnderstandingError.noPanelFound` when the image
    ///   contains nothing panel-shaped, `.undecodableImage` when it will not
    ///   decode at all.
    public func detectPanel(
        in photo: PanelPhoto
    ) async throws -> (quad: PanelQuad, confidence: Double) {
        let result = try await analyze(photo)
        return (result.quad, result.confidence)
    }

    private func analyze(_ photo: PanelPhoto) async throws
        -> (quad: PanelQuad, confidence: Double, estimatedAlignment: Bool, warnings: [String]) {
        guard !Task.isCancelled else {
            throw SurfaceUnderstandingError.cancelled
        }

        // Decode the original image pixels.
        guard
            let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw SurfaceUnderstandingError.undecodableImage
        }

        // Tell Vision how to interpret the image upright.
        let orientation: CGImagePropertyOrientation
        switch photo.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 10
        request.minimumConfidence = 0.3
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1
        request.quadratureTolerance = 45

        // Match ButtonDetector's key request, without adding OCR to this path.
        let keys = VNDetectRectanglesRequest()
        keys.maximumObservations = 30
        keys.minimumSize = 0.03
        keys.minimumConfidence = 0.5
        keys.minimumAspectRatio = 0.3
        keys.maximumAspectRatio = 1.0

        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
            guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled }
            // Separate calls avoid a Vision hang during concurrent Swift tests.
            try handler.perform([keys])
        } catch {
            if Task.isCancelled || error is CancellationError ||
                (error as? SurfaceUnderstandingError) == .cancelled {
                throw SurfaceUnderstandingError.cancelled
            }
            throw SurfaceUnderstandingError.underlying(error.localizedDescription)
        }

        guard !Task.isCancelled else {
            throw SurfaceUnderstandingError.cancelled
        }

        // Use actual corner area, including for perspective-skewed rectangles.
        func area(_ rectangle: VNRectangleObservation) -> CGFloat {
            let points = [
                rectangle.topLeft,
                rectangle.topRight,
                rectangle.bottomRight,
                rectangle.bottomLeft
            ]

            var total: CGFloat = 0
            for index in points.indices {
                let next = points[(index + 1) % points.count]
                total += points[index].x * next.y
                    - next.x * points[index].y
            }

            return abs(total) / 2
        }

        let rectangles = request.results ?? []
        guard let largest = rectangles.max(by: { area($0) < area($1) }) else {
            throw SurfaceUnderstandingError.noPanelFound
        }

        // Vision uses bottom-left origin; Contour uses top-left.
        func imagePoint(_ point: CGPoint) -> ImagePoint {
            ImagePoint(x: Double(point.x), y: 1.0 - Double(point.y))
        }
        func panelQuad(_ rectangle: VNRectangleObservation) -> PanelQuad {
            PanelQuad(topLeft: imagePoint(rectangle.topLeft),
                      topRight: imagePoint(rectangle.topRight),
                      bottomRight: imagePoint(rectangle.bottomRight),
                      bottomLeft: imagePoint(rectangle.bottomLeft))
        }

        let keyBoxes = keys.results ?? []
        let candidates = rectangles.map { rectangle in
            let quad = panelQuad(rectangle)
            let candidateArea = area(rectangle)
            let count = keyBoxes.filter { key in
                // The second request can find the panel itself or the door.
                guard area(key) < candidateArea * 0.5 else { return false }
                let center = CGPoint(x: key.boundingBox.midX, y: key.boundingBox.midY)
                return rectify(imagePoint(center), within: quad).isOnPanel
            }.count
            return (rectangle: rectangle, area: candidateArea, count: count)
        }
        let mostKeys = candidates.map(\.count).max() ?? 0
        let rectangle: VNRectangleObservation
        if mostKeys >= 3 {
            // Prefer a tight panel over a control column with a barcode or trim
            // when both contain essentially the same number of keys.
            rectangle = candidates.filter { $0.count >= 3 && Double($0.count) >= Double(mostKeys) * 0.9 }
                .min(by: { $0.area < $1.area })!.rectangle
        } else if keyBoxes.count >= 3 {
            // The keypad is visible, but its enclosing border may be off-camera.
            return (.fullFrame, 0.6, false, [])
        } else {
            // Sparse evidence still preserves lone rectangles and simple panels.
            rectangle = largest
        }
        let seed = panelQuad(rectangle)
        let keyCorners = keyBoxes.filter { area($0) < area(rectangle) * 0.5 }.map { key in
            [key.topLeft, key.topRight, key.bottomRight, key.bottomLeft].map(imagePoint)
        }
        // Vision can extrapolate a rectangle's corners past the photo's edges.
        let quad = clampedToPhoto(enclosingKeyGroups(seed: seed, keys: keyCorners))
        let expanded = quad != seed
        let confidence = min(Double(rectangle.confidence), expanded ? 0.85 : 1)

        guard expandWithText else {
            return (quad, confidence, expanded, [])
        }

        // A strong rectangle can be only one button bank. Use nearby text to
        // include the display and keypad rather than equating rectangle confidence
        // with confidence that the entire panel has been found.
        let refined = try refinePanel(seed: quad, confidence: confidence) {
            try controlEvidence(in: image, orientation: orientation, seed: quad)
        }
        guard isInsidePhoto(refined.quad) else { return (quad, confidence, expanded, refined.warnings) }
        return (refined.quad, refined.confidence, expanded || refined.estimatedAlignment, refined.warnings)
    }

    /// How far a corner may sit outside the photo. Vision's rectangle tracker
    /// can refuse a reference quad whose corners leave the image, and then the
    /// panel cannot be tracked at all, not even on the first frame.
    static let frameTolerance = 0.02

    func isInsidePhoto(_ quad: PanelQuad) -> Bool {
        let range = -Self.frameTolerance...(1 + Self.frameTolerance)
        return [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
            .allSatisfy { range.contains($0.x) && range.contains($0.y) }
    }

    /// A grown outline that would leave the photo is not used at all; this is
    /// for a detected rectangle that already does.
    func clampedToPhoto(_ quad: PanelQuad) -> PanelQuad {
        guard !isInsidePhoto(quad) else { return quad }
        func clamped(_ point: ImagePoint) -> ImagePoint {
            ImagePoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        return PanelQuad(topLeft: clamped(quad.topLeft), topRight: clamped(quad.topRight),
                         bottomRight: clamped(quad.bottomRight), bottomLeft: clamped(quad.bottomLeft))
    }

    /// A close-up may expose a border around presets, but no border around the
    /// whole keypad. Require more keys continuing the group's columns past its
    /// ends than lie inside it, then grow over those keys and nothing else: a
    /// door, handle, stove strip or cabinet edge in the same column is not a key
    /// of this panel. The grown outline must stay in the photo.
    /// This uses rectangle evidence only; text recognition remains opt-in.
    func enclosingKeyGroups(seed: PanelQuad, keys: [[ImagePoint]]) -> PanelQuad {
        struct Key {
            var corners: [ImagePoint]
            var center: PanelPoint
            var left, top, right, bottom: Double
            var width: Double { right - left }
            var height: Double { bottom - top }
            func contains(_ point: PanelPoint) -> Bool {
                (left...right).contains(point.x) && (top...bottom).contains(point.y)
            }
        }
        let mapped = keys.compactMap { corners -> Key? in
            guard corners.count == 4 else { return nil }
            let center = rectify(ImagePoint(x: (corners.map(\.x).min()! + corners.map(\.x).max()!) / 2,
                                            y: (corners.map(\.y).min()! + corners.map(\.y).max()!) / 2),
                                 within: seed)
            let points = corners.map { rectify($0, within: seed) }
            guard center.x.isFinite, center.y.isFinite,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            return Key(corners: corners, center: center,
                       left: points.map(\.x).min()!, top: points.map(\.y).min()!,
                       right: points.map(\.x).max()!, bottom: points.map(\.y).max()!)
        }
        let inside = mapped.filter { $0.center.isOnPanel }
        guard inside.count >= 3 else { return seed }

        // Vision also boxes the text printed on a key. Size keys by the outer boxes.
        let outer = inside.filter { key in
            !inside.contains { $0.width * $0.height > key.width * key.height && $0.contains(key.center) }
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let keyWidth = median(outer.map(\.width))
        let keyHeight = median(outer.map(\.height))

        func keySized(_ key: Key) -> Bool {
            (0.5 * keyWidth...2 * keyWidth).contains(key.width) &&
            (0.5 * keyHeight...2 * keyHeight).contains(key.height)
        }
        // A display is wider than a key column; only keys define the columns.
        let columns = outer.filter(keySized)
        // In one of the group's key columns, and no bigger than about two keys.
        var candidates = mapped.filter { key in
            !key.center.isOnPanel && (0...1).contains(key.center.x) &&
            key.width <= 2 * keyWidth && key.height <= 2 * keyHeight &&
            columns.contains { abs(key.center.x - $0.center.x) <= 0.5 * $0.width }
        }
        // Chained to the group's edge. Below, a caption row such as "Express Cook"
        // can separate the keypad from the presets; above sits the display.
        var top = 0.0, bottom = 1.0
        var chained: [Key] = []
        var grew = true
        while grew {
            grew = false
            candidates.removeAll { key in
                if key.center.y < 0, top - key.bottom < 1.25 * keyHeight {
                    top = min(top, key.top)
                } else if key.center.y > 1, key.top - bottom < 2.5 * keyHeight {
                    bottom = max(bottom, key.bottom)
                } else {
                    return false
                }
                chained.append(key)
                grew = true
                return true
            }
        }
        // Text boxes may extend the chain, but it takes key-sized boxes to start it.
        guard chained.count > inside.count, chained.filter(keySized).count >= 2 else { return seed }

        let grown = enclosingControls(seed: seed, evidence: (inside + chained).map(\.corners))
        // A keypad roughly doubles a preset group; much more is not this panel.
        guard area(grown) <= 2.75 * area(seed), isInsidePhoto(grown) else { return seed }
        return grown
    }

    /// Shoelace area of a quad in normalized image units.
    private func area(_ quad: PanelQuad) -> Double {
        let points = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var total = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            total += points[index].x * next.y - next.x * points[index].y
        }
        return abs(total) / 2
    }

    /// OCR is optional refinement. A failure must not discard a valid rectangle.
    func refinePanel(seed: PanelQuad, confidence: Double,
                     evidence: () throws -> (labels: [[ImagePoint]], displays: [[ImagePoint]])) throws
        -> (quad: PanelQuad, confidence: Double, estimatedAlignment: Bool, warnings: [String]) {
        guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled }
        do {
            let found = try evidence()
            guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled }
            let enclosing = enclosingControls(seed: seed, evidence: found.labels, displays: found.displays)
            return (enclosing, min(confidence, enclosing == seed ? 1 : 0.85), enclosing != seed, [])
        } catch {
            if Task.isCancelled || error is CancellationError ||
                (error as? SurfaceUnderstandingError) == .cancelled {
                throw SurfaceUnderstandingError.cancelled
            }
            return (seed, confidence, false,
                    ["Text recognition failed; using the detected rectangle without expanding it. The crop may omit controls; review it visually."])
        }
    }

    /// Grow a detected button rectangle to include nearby controls in the same column.
    /// Evidence is expressed in the upright source image, never in raw EXIF pixels.
    func enclosingControls(seed: PanelQuad, evidence: [[ImagePoint]], displays: [[ImagePoint]] = []) -> PanelQuad {
        struct Bounds {
            var left: Double
            var top: Double
            var right: Double
            var bottom: Double
        }
        let boxes = evidence.compactMap { points -> Bounds? in
            let mapped = points.map { rectify($0, within: seed) }
            guard mapped.count >= 4, mapped.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let box = Bounds(left: mapped.map(\.x).min()!, top: mapped.map(\.y).min()!,
                             right: mapped.map(\.x).max()!, bottom: mapped.map(\.y).max()!)
            // Stay in the control column; reject distant branding and large scene rectangles.
            guard box.left >= -0.55, box.right <= 1.55,
                  box.top >= -1.8, box.bottom <= 3.5,
                  box.right - box.left < 1.7, box.bottom - box.top < 1.2 else { return nil }
            return box
        }
        // Do not enlarge an arbitrary cabinet/door rectangle without control evidence.
        guard boxes.filter({ $0.right > 0 && $0.left < 1 && $0.bottom > 0 && $0.top < 1 }).count >= 3 else {
            return seed
        }
        // If the detected boundary already contains a display with controls on
        // both sides and below, retain that boundary instead of growing to branding.
        for display in displays {
            let points = display.map { rectify($0, within: seed) }
            guard points.count == 4, points.allSatisfy({ $0.isOnPanel }) else { continue }
            let left = points.map(\.x).min()!
            let right = points.map(\.x).max()!
            let bottom = points.map(\.y).max()!
            let inside = boxes.filter { $0.left >= 0 && $0.right <= 1 && $0.top >= 0 && $0.bottom <= 1 }
            if inside.contains(where: { $0.right < left }),
               inside.contains(where: { $0.left > right }),
               inside.contains(where: { $0.top > bottom }) {
                return seed
            }
        }
        let interiorHeights = boxes.filter { $0.left >= 0 && $0.right <= 1 && $0.top >= 0 && $0.bottom <= 1 }
            .map { $0.bottom - $0.top }.sorted()
        let typicalHeight = interiorHeights.isEmpty ? 1 : interiorHeights[interiorHeights.count / 2]
        var bounds = Bounds(left: 0, top: 0, right: 1, bottom: 1)
        // Isolated oversized evidence below a panel is often branding or trim.
        // Preserve larger keys or keypad digits that share a row with nearby evidence.
        var remaining = boxes.filter { box in
            guard box.top > 1, box.bottom - box.top > typicalHeight * 2 else { return true }
            return boxes.contains { other in
                (other.right < box.left || other.left > box.right) &&
                min(other.bottom, box.bottom) > max(other.top, box.top)
            }
        }
        var grew = true
        while grew {
            grew = false
            remaining.removeAll { box in
                let gap = max(0, max(bounds.top - box.bottom, box.top - bounds.bottom))
                guard gap <= 0.65, box.right >= bounds.left, box.left <= bounds.right else { return false }
                bounds.left = min(bounds.left, box.left)
                bounds.right = max(bounds.right, box.right)
                bounds.top = min(bounds.top, box.top)
                bounds.bottom = max(bounds.bottom, box.bottom)
                grew = true
                return true
            }
        }
        // Padding includes button outlines, rather than trimming to the glyphs.
        bounds.left -= 0.04
        bounds.right += 0.04
        bounds.top -= 0.10
        bounds.bottom += 0.10

        // Invert the seed homography by treating source x/y as target coordinates.
        func mapped(_ x: Double, _ y: Double) -> ImagePoint {
            let point = rectify(ImagePoint(x: x, y: y), within: seed)
            return ImagePoint(x: point.x, y: point.y)
        }
        let inverseQuad = PanelQuad(topLeft: mapped(0, 0), topRight: mapped(1, 0),
                                    bottomRight: mapped(1, 1), bottomLeft: mapped(0, 1))
        func source(_ x: Double, _ y: Double) -> ImagePoint {
            let point = rectify(ImagePoint(x: x, y: y), within: inverseQuad)
            return ImagePoint(x: point.x, y: point.y)
        }
        let corners = [source(bounds.left, bounds.top), source(bounds.right, bounds.top),
                       source(bounds.right, bounds.bottom), source(bounds.left, bounds.bottom)]
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 3 && abs($0.y) < 3 }) else {
            return seed
        }
        // Keep the projective geometry even if the photographed panel meets the frame edge.
        // Core Image leaves any genuinely missing source pixels transparent.
        return PanelQuad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
    }

    private func controlEvidence(in image: CGImage, orientation: CGImagePropertyOrientation,
                                 seed: PanelQuad) throws -> (labels: [[ImagePoint]], displays: [[ImagePoint]]) {
        let upright = CIImage(cgImage: image).oriented(orientation)
        // Deskew first so OCR can read labels even when the camera is tilted 45 degrees.
        let dx = (seed.topRight.x - seed.topLeft.x) * upright.extent.width
        let dy = -(seed.topRight.y - seed.topLeft.y) * upright.extent.height
        let rotation = CGAffineTransform(rotationAngle: -atan2(dy, dx))
        let rotated = upright.transformed(by: rotation)
        let extent = rotated.extent.integral
        let scale = min(1, 2000 / max(extent.width, extent.height))
        let transform = rotation.concatenating(CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let prepared = upright.transformed(by: transform)
        let renderBounds = CGRect(x: 0, y: 0, width: ceil(extent.width * scale), height: ceil(extent.height * scale))
        guard let pixels = CIContext().createCGImage(prepared, from: renderBounds) else {
            throw SurfaceUnderstandingError.underlying("Could not prepare the image for text recognition")
        }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: pixels, options: [:]).perform([text])
        let inverse = transform.inverted()
        var labels = [[ImagePoint]]()
        var displays = [[ImagePoint]]()
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { continue }
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft].map {
                let pixel = CGPoint(x: $0.x * renderBounds.width, y: $0.y * renderBounds.height).applying(inverse)
                return ImagePoint(x: (pixel.x - upright.extent.minX) / upright.extent.width,
                                  y: 1 - (pixel.y - upright.extent.minY) / upright.extent.height)
            }
            labels.append(corners)
            let value = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.range(of: #"^\d{1,2}[:.]\d{2}$"#, options: .regularExpression) != nil {
                displays.append(corners)
            }
        }
        return (labels, displays)
    }

    /// Return a 1024-pixel-wide upright crop, original upright-image corners, and confidence.
    /// The caller supplies orientation through `PanelPhoto`, just as for detection.
    /// `warnings` reports OCR fallback, out-of-frame crops, and estimated alignment. Display these
    /// alongside the image; absence of warnings is not a quality guarantee.
    public func detect(_ photo: PanelPhoto) async throws -> (image: CGImage, quad: PanelQuad, confidence: Double, warnings: [String]) {
        let result = try await analyze(photo)
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SurfaceUnderstandingError.undecodableImage
        }
        let orientation: CGImagePropertyOrientation
        switch photo.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        let upright = CIImage(cgImage: pixels).oriented(orientation)
        let extent = upright.extent
        func vector(_ point: ImagePoint) -> CIVector {
            CIVector(x: extent.minX + CGFloat(point.x) * extent.width,
                     y: extent.minY + CGFloat(1 - point.y) * extent.height)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw SurfaceUnderstandingError.underlying("Perspective correction is unavailable")
        }
        filter.setValue(upright, forKey: kCIInputImageKey)
        filter.setValue(vector(result.quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(result.quad.topRight), forKey: "inputTopRight")
        filter.setValue(vector(result.quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(vector(result.quad.bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage,
              !output.extent.isEmpty, !output.extent.isInfinite else {
            throw SurfaceUnderstandingError.underlying("Could not straighten the panel")
        }
        // A fixed width gives downstream readers a consistent scale.
        let width = 1024
        let height = max(1, Int((CGFloat(width) * output.extent.height / output.extent.width).rounded()))
        let normalized = output.transformed(by: CGAffineTransform(
            translationX: -output.extent.minX, y: -output.extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / output.extent.width,
            y: CGFloat(height) / output.extent.height))
        guard let image = CIContext().createCGImage(
            scaled, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw SurfaceUnderstandingError.underlying("Could not render the straightened panel")
        }
        guard !Task.isCancelled else { throw SurfaceUnderstandingError.cancelled }
        return (image: image, quad: result.quad, confidence: result.confidence,
                warnings: result.warnings + cropWarnings(quad: result.quad, estimatedAlignment: result.estimatedAlignment))
    }

    /// Conservative review notices, not a measured alignment score.
    /// An empty list does not guarantee a correct crop or perfect alignment.
    func cropWarnings(quad: PanelQuad, estimatedAlignment: Bool) -> [String] {
        var warnings = [String]()
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        if corners.contains(where: { !(0...1).contains($0.x) || !(0...1).contains($0.y) }) {
            warnings.append("Crop extends beyond the original photo; missing panel content cannot be recovered.")
        }
        if estimatedAlignment {
            warnings.append("Alignment needs visual review: the crop was expanded from a smaller rectangle, so some controls may remain slanted.")
        }
        return warnings
    }

    /// Map an upright image point to the panel unit square with a homography.
    /// Off-panel values are preserved. A degenerate quad returns NaN coordinates.
    public func rectify(_ point: ImagePoint, within quad: PanelQuad) -> PanelPoint {
        let source = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        let target: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        var rows = [[Double]]()
        for (p, (u, v)) in zip(source, target) {
            rows.append([p.x, p.y, 1, 0, 0, 0, -u * p.x, -u * p.y, u])
            rows.append([0, 0, 0, p.x, p.y, 1, -v * p.x, -v * p.y, v])
        }
        // Solve the eight projective coefficients using partial pivoting.
        for column in 0..<8 {
            let pivot = (column..<8).max { abs(rows[$0][column]) < abs(rows[$1][column]) }!
            guard rows[pivot][column].isFinite, abs(rows[pivot][column]) > 1e-12 else {
                return PanelPoint(x: .nan, y: .nan)
            }
            rows.swapAt(column, pivot)
            let scale = rows[column][column]
            for j in column...8 { rows[column][j] /= scale }
            for i in 0..<8 where i != column {
                let factor = rows[i][column]
                for j in column...8 { rows[i][j] -= factor * rows[column][j] }
            }
        }
        let h = rows.map { $0[8] }
        let denominator = h[6] * point.x + h[7] * point.y + 1
        guard denominator.isFinite, abs(denominator) > 1e-12 else {
            return PanelPoint(x: .nan, y: .nan)
        }
        return PanelPoint(x: (h[0] * point.x + h[1] * point.y + h[2]) / denominator,
                          y: (h[3] * point.x + h[4] * point.y + h[5]) / denominator)
    }
}
