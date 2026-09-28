//
//  PanelDetector.swift
//  SurfaceUnderstanding — Surface / Panel Reader
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

    public init() {}

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
        request.minimumConfidence = 0.7
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.1
        request.quadratureTolerance = 45

        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            throw SurfaceUnderstandingError.underlying(error.localizedDescription)
        }

        guard !Task.isCancelled else {
            throw SurfaceUnderstandingError.cancelled
        }

        // Pick the largest qualifying rectangle by its actual corner area.
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

        guard let rectangle = request.results?
            .filter({ $0.confidence >= 0.7 })
            .max(by: { area($0) < area($1) })
        else {
            throw SurfaceUnderstandingError.noPanelFound
        }

        // Vision uses bottom-left origin; Contour uses top-left.
        func imagePoint(_ point: CGPoint) -> ImagePoint {
            ImagePoint(x: Double(point.x), y: 1.0 - Double(point.y))
        }

        let quad = PanelQuad(
            topLeft: imagePoint(rectangle.topLeft),
            topRight: imagePoint(rectangle.topRight),
            bottomRight: imagePoint(rectangle.bottomRight),
            bottomLeft: imagePoint(rectangle.bottomLeft)
        )

        // A strong rectangle can be only one button bank. Use nearby text to
        // include the display and keypad rather than equating rectangle confidence
        // with confidence that the entire panel has been found.
        return try refinePanel(seed: quad, confidence: Double(rectangle.confidence)) {
            try controlEvidence(in: image, orientation: orientation, seed: quad)
        }
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
        // Isolated oversized text below a panel is often branding, not a control.
        // Preserve large keypad digits that form a row with other nearby evidence.
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
