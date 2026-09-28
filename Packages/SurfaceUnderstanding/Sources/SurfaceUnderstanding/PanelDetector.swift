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

        return (quad: quad, confidence: Double(rectangle.confidence))
    }

    /// Return a 1024-pixel-wide upright crop, original upright-image corners, and confidence.
    /// The caller supplies orientation through `PanelPhoto`, just as for detection.
    public func detect(_ photo: PanelPhoto) async throws -> (image: CGImage, quad: PanelQuad, confidence: Double) {
        let result = try await detectPanel(in: photo)
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
        return (image: image, quad: result.quad, confidence: result.confidence)
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
