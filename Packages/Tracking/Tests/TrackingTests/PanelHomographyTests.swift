//
//  PanelHomographyTests.swift
//  Tracking — Tracking / Geometry
//

import ContourCore
import Foundation
import Testing
@testable import Tracking

/// Matrix inversion leaves rounding error around 1e-15; anything under this is equal.
private let tolerance = 1e-9

private func isClose(_ a: PanelPoint, _ b: PanelPoint) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

private func isClose(_ a: ImagePoint, _ b: ImagePoint) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

/// A panel seen straight on, inset from the frame edges.
private let straightOn = PanelQuad(topLeft: ImagePoint(x: 0.2, y: 0.2),
                                   topRight: ImagePoint(x: 0.8, y: 0.2),
                                   bottomRight: ImagePoint(x: 0.8, y: 0.8),
                                   bottomLeft: ImagePoint(x: 0.2, y: 0.8))

/// A panel seen at an angle: no two edges parallel.
private let distorted = PanelQuad(topLeft: ImagePoint(x: 0.3, y: 0.2),
                                  topRight: ImagePoint(x: 0.7, y: 0.25),
                                  bottomRight: ImagePoint(x: 0.9, y: 0.85),
                                  bottomLeft: ImagePoint(x: 0.1, y: 0.8))

/// Where lines `a1→a2` and `b1→b2` cross.
private func intersection(_ a1: ImagePoint, _ a2: ImagePoint,
                          _ b1: ImagePoint, _ b2: ImagePoint) -> ImagePoint {
    let d = (a2.x - a1.x) * (b2.y - b1.y) - (a2.y - a1.y) * (b2.x - b1.x)
    let t = ((b1.x - a1.x) * (b2.y - b1.y) - (b1.y - a1.y) * (b2.x - b1.x)) / d
    return ImagePoint(x: a1.x + t * (a2.x - a1.x), y: a1.y + t * (a2.y - a1.y))
}

@Test("a full-frame panel maps image space straight through")
func fullFrameIsIdentity() throws {
    let homography = try PanelHomography(quad: .fullFrame)
    for (x, y) in [(0.0, 0.0), (0.25, 0.75), (0.5, 0.5), (1.0, 1.0)] {
        let panel = try #require(homography.panelPoint(for: ImagePoint(x: x, y: y)))
        #expect(isClose(panel, PanelPoint(x: x, y: y)), "\(panel)")
    }
}

@Test("each corner maps to its panel corner", arguments: [straightOn, distorted])
func cornersMapExactly(quad: PanelQuad) throws {
    let homography = try PanelHomography(quad: quad)
    let pairs = [(quad.topLeft, PanelPoint(x: 0, y: 0)),
                 (quad.topRight, PanelPoint(x: 1, y: 0)),
                 (quad.bottomRight, PanelPoint(x: 1, y: 1)),
                 (quad.bottomLeft, PanelPoint(x: 0, y: 1))]
    for (image, expected) in pairs {
        let panel = try #require(homography.panelPoint(for: image))
        #expect(isClose(panel, expected), "\(image) → \(panel)")
    }
}

@Test("straight on, interior points scale linearly")
func straightOnInterior() throws {
    let homography = try PanelHomography(quad: straightOn)
    // (0.35, 0.65) is a quarter and three quarters of the way across the 0.2...0.8 inset.
    let panel = try #require(homography.panelPoint(for: ImagePoint(x: 0.35, y: 0.65)))
    #expect(isClose(panel, PanelPoint(x: 0.25, y: 0.75)), "\(panel)")
}

@Test("under perspective, the panel centre is where the diagonals cross")
func distortedCentre() throws {
    let homography = try PanelHomography(quad: distorted)
    let crossing = intersection(distorted.topLeft, distorted.bottomRight,
                                distorted.topRight, distorted.bottomLeft)
    let panel = try #require(homography.panelPoint(for: crossing))
    #expect(isClose(panel, .center), "\(panel)")
    // Perspective means this is not the average of the corners.
    let corners = [distorted.topLeft, distorted.topRight, distorted.bottomRight, distorted.bottomLeft]
    let average = ImagePoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
    #expect(hypot(crossing.x - average.x, crossing.y - average.y) > 0.005)
}

@Test("off-panel points are reported outside 0...1, never clamped")
func offPanelIsUnclamped() throws {
    let homography = try PanelHomography(quad: straightOn)

    let left = try #require(homography.panelPoint(for: ImagePoint(x: 0.1, y: 0.5)))
    #expect(isClose(left, PanelPoint(x: -1.0 / 6, y: 0.5)), "\(left)")
    #expect(!left.isOnPanel)

    let belowRight = try #require(homography.panelPoint(for: ImagePoint(x: 0.9, y: 0.9)))
    #expect(isClose(belowRight, PanelPoint(x: 7.0 / 6, y: 7.0 / 6)), "\(belowRight)")
    #expect(!belowRight.isOnPanel)
}

@Test("degenerate quads are rejected", arguments: [
    // Collinear: TL, TR and BR on one line.
    PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.1), topRight: ImagePoint(x: 0.5, y: 0.1),
              bottomRight: ImagePoint(x: 0.9, y: 0.1), bottomLeft: ImagePoint(x: 0.1, y: 0.9)),
    // Repeated corner: TR on top of TL.
    PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.1), topRight: ImagePoint(x: 0.1, y: 0.1),
              bottomRight: ImagePoint(x: 0.9, y: 0.9), bottomLeft: ImagePoint(x: 0.1, y: 0.9)),
    // Bowtie: BR and BL swapped, so the edges cross.
    PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.1), topRight: ImagePoint(x: 0.9, y: 0.1),
              bottomRight: ImagePoint(x: 0.1, y: 0.9), bottomLeft: ImagePoint(x: 0.9, y: 0.9)),
    // y-up: the top corners have the larger y, flipping the winding.
    PanelQuad(topLeft: ImagePoint(x: 0.1, y: 0.9), topRight: ImagePoint(x: 0.9, y: 0.9),
              bottomRight: ImagePoint(x: 0.9, y: 0.1), bottomLeft: ImagePoint(x: 0.1, y: 0.1)),
    // Non-finite coordinate.
    PanelQuad(topLeft: ImagePoint(x: .nan, y: 0.1), topRight: ImagePoint(x: 0.9, y: 0.1),
              bottomRight: ImagePoint(x: 0.9, y: 0.9), bottomLeft: ImagePoint(x: 0.1, y: 0.9)),
])
func degenerateQuadsThrow(quad: PanelQuad) {
    #expect(throws: PanelHomography.GeometryError.degenerateQuad) {
        try PanelHomography(quad: quad)
    }
}

@Test("a target drawn on the image maps back to the same target")
func targetRoundTrip() throws {
    let homography = try PanelHomography(quad: distorted)
    let target = PanelPoint(x: 0.3, y: 0.6)

    let onImage = try #require(homography.imagePoint(for: target))
    let back = try #require(homography.panelPoint(for: onImage))
    #expect(isClose(back, target), "\(target) → \(onImage) → \(back)")

    // The inverse agrees with the corners it was built from.
    let corner = try #require(homography.imagePoint(for: PanelPoint(x: 1, y: 1)))
    #expect(isClose(corner, distorted.bottomRight), "\(corner)")
}
