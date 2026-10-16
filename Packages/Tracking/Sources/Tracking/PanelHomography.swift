//
//  PanelHomography.swift
//  Tracking — Tracking / Geometry
//
//  Maps between image space (ImagePoint) and normalized panel space (PanelPoint)
//  using the four corners of a PanelQuad. Pure math: no camera, no detection.
//
//

import ContourCore
import Foundation
import simd

public struct PanelHomography: Sendable {
    public enum GeometryError: Error { case degenerateQuad }

    /// Panel → image.
    private let toImage: simd_double3x3
    /// Image → panel.
    private let toPanel: simd_double3x3

    /// Throws `degenerateQuad` if the corners can't define a real panel.
    public init(quad: PanelQuad) throws {
        guard Self.isValid(quad) else { throw GeometryError.degenerateQuad }
        guard let toImage = Self.squareToQuad(quad) else { throw GeometryError.degenerateQuad }
        // A singular matrix has no inverse: image points couldn't be mapped back.
        guard abs(toImage.determinant) > Self.epsilon else { throw GeometryError.degenerateQuad }
        self.toImage = toImage
        self.toPanel = toImage.inverse
    }

    /// Where an image-space point lands on the panel. `nil` if it can't be mapped.
    /// Not clamped: values outside `0...1` mean the point is off the panel.
    public func panelPoint(for p: ImagePoint) -> PanelPoint? {
        guard let (x, y) = Self.apply(toPanel, p.x, p.y) else { return nil }
        return PanelPoint(x: x, y: y)
    }

    /// Where a panel-space point lands in the image, e.g. to draw a target.
    public func imagePoint(for p: PanelPoint) -> ImagePoint? {
        guard let (x, y) = Self.apply(toImage, p.x, p.y) else { return nil }
        return ImagePoint(x: x, y: y)
    }

    /// Multiplies `(x, y, 1)` by `matrix` and divides by the resulting `w`.
    ///
    /// `w` is positive for every point on the camera's side of the panel's horizon
    /// line. At or past that line the point has no real counterpart, so return `nil`
    /// rather than a huge or mirrored coordinate.
    private static func apply(_ matrix: simd_double3x3, _ x: Double, _ y: Double) -> (Double, Double)? {
        guard x.isFinite, y.isFinite else { return nil }
        let r = matrix * SIMD3(x, y, 1)
        guard r.z > epsilon else { return nil }
        return (r.x / r.z, r.y / r.z)
    }

    // MARK: - Matrix

    /// The homography taking the unit square onto `quad`: panel (0,0)/(1,0)/(1,1)/(0,1)
    /// → image TL/TR/BR/BL. Closed-form square-to-quad (Heckbert, 1989).
    /// `nil` if the quad's far corner makes the system singular.
    static func squareToQuad(_ quad: PanelQuad) -> simd_double3x3? {
        let (x0, y0) = (quad.topLeft.x, quad.topLeft.y)
        let (x1, y1) = (quad.topRight.x, quad.topRight.y)
        let (x2, y2) = (quad.bottomRight.x, quad.bottomRight.y)
        let (x3, y3) = (quad.bottomLeft.x, quad.bottomLeft.y)

        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3

        let den = dx1 * dy2 - dx2 * dy1
        guard abs(den) > epsilon else { return nil }

        // Perspective terms. Both are 0 for a parallelogram (e.g. a straight-on panel).
        let g = (dx3 * dy2 - dx2 * dy3) / den
        let h = (dx1 * dy3 - dx3 * dy1) / den

        return simd_double3x3(rows: [
            SIMD3(x1 - x0 + g * x1, x3 - x0 + h * x3, x0),
            SIMD3(y1 - y0 + g * y1, y3 - y0 + h * y3, y0),
            SIMD3(g, h, 1),
        ])
    }

    // MARK: - Validation

    /// Cross products below this are treated as zero (corners in a line).
    static let epsilon = 1e-9
    /// Smallest accepted quad area, as a fraction of the image (0.1% × 0.1%).
    static let minimumArea = 1e-6

    /// A usable quad is finite, strictly convex, large enough, and wound
    /// TL → TR → BR → BL clockwise on screen (y down). Anything else — collinear
    /// or repeated corners, a bowtie, a mirrored or y-up quad — is rejected.
    static func isValid(_ quad: PanelQuad) -> Bool {
        let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }

        // At each corner b, the turn from edge a→b to edge b→c. In y-down image
        // space a clockwise turn is positive, so every corner must be > 0.
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            let c = corners[(i + 2) % 4]
            let turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard turn > epsilon else { return false }
        }

        // Shoelace formula; positive for the same clockwise winding.
        var twiceArea = 0.0
        for i in 0..<4 {
            let p = corners[i], q = corners[(i + 1) % 4]
            twiceArea += p.x * q.y - q.x * p.y
        }
        return twiceArea / 2 >= minimumArea
    }
}
