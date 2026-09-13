//
//  Coordinates.swift
//  ContourCore
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  DRAFT — FROZEN END OF WEEK 2                                            │
//  │                                                                          │
//  │  This file is the shared contract between all four teams. Until the end  │
//  │  of Week 2 it is open for discussion: file an issue, bring it to a lead. │
//  │  After the freeze, a change here needs sign-off from ALL FOUR team leads │
//  │  because it breaks everyone at once.                                     │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  COORDINATE CONVENTION — see Packages/ContourCore/COORDINATES.md
//
//      x = 0                                   x = 1
//  y=0  +-------------------------------------+
//       |  (0,0) top-left                     |
//       |                                     |   y increases DOWNWARD
//       |                                     |            |
//       |                        (1,1)        |            v
//  y=1  +-------------------------------------+
//
//  Normalized panel space. Origin top-left, (1,1) bottom-right, y down.
//  Values outside 0...1 are legal — they mean "off the panel".
//

import Foundation

// MARK: - PanelPoint

/// A position on the control panel, in **normalized panel space**.
///
/// `(0, 0)` is the top-left corner of the panel, `(1, 1)` the bottom-right, and
/// `y` increases **downward**. Values outside `0...1` are legal and mean the
/// point is off the edge of the panel — do not clamp them silently.
///
/// See `Packages/ContourCore/COORDINATES.md` for the full convention.
public struct PanelPoint: Hashable, Sendable, Codable {

    /// Horizontal position. `0` is the panel's left edge, `1` its right edge.
    public var x: Double

    /// Vertical position. `0` is the panel's **top** edge, `1` its bottom edge.
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The centre of the panel, `(0.5, 0.5)`.
    public static let center = PanelPoint(x: 0.5, y: 0.5)

    /// The panel's origin corner, `(0, 0)` — top-left.
    public static let origin = PanelPoint(x: 0, y: 0)

    /// Whether this point lies within the panel's bounds, inclusive.
    public var isOnPanel: Bool {
        (0...1).contains(x) && (0...1).contains(y)
    }

    /// The displacement from this point to `other`.
    public func vector(to other: PanelPoint) -> PanelVector {
        PanelVector(dx: other.x - x, dy: other.y - y)
    }

    /// Straight-line distance to `other`, in panel units.
    ///
    /// Note that a "panel unit" is not a physical length: the panel is normalized
    /// to a unit square regardless of its real-world aspect ratio, so horizontal
    /// and vertical units are only equal in millimetres on a square panel.
    public func distance(to other: PanelPoint) -> Double {
        vector(to: other).magnitude
    }

    /// This point moved by `vector`.
    public func offset(by vector: PanelVector) -> PanelPoint {
        PanelPoint(x: x + vector.dx, y: y + vector.dy)
    }
}

// MARK: - PanelVector

/// A displacement between two `PanelPoint`s, in **normalized panel space**.
///
/// Same axis convention as `PanelPoint`: `+dx` points right, `+dy` points
/// **down**. A vector of `(0, -0.2)` points *up* the panel.
public struct PanelVector: Hashable, Sendable, Codable {

    /// Horizontal component. Positive is rightward.
    public var dx: Double

    /// Vertical component. Positive is **downward**.
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = PanelVector(dx: 0, dy: 0)

    /// Euclidean length of the vector.
    public var magnitude: Double {
        (dx * dx + dy * dy).squareRoot()
    }

    /// The same direction with length `1`, or `nil` if this is the zero vector.
    public var normalized: PanelVector? {
        let m = magnitude
        guard m > 0 else { return nil }
        return PanelVector(dx: dx / m, dy: dy / m)
    }

    /// Direction in radians, measured clockwise from "right" because `y` is down.
    ///
    /// `0` is right, `π/2` is **down**, `π` is left, `-π/2` is up.
    public var angle: Double {
        atan2(dy, dx)
    }
}

// MARK: - PanelRect

/// An axis-aligned rectangle on the panel, in **normalized panel space**.
///
/// `origin` is the **top-left** corner and `y` grows downward, so
/// `origin.y + height` is the rectangle's *bottom* edge.
public struct PanelRect: Hashable, Sendable, Codable {

    /// The **top-left** corner of the rectangle.
    public var origin: PanelPoint

    /// Width as a fraction of the panel's width. Expected to be non-negative.
    public var width: Double

    /// Height as a fraction of the panel's height. Expected to be non-negative.
    public var height: Double

    public init(origin: PanelPoint, width: Double, height: Double) {
        self.origin = origin
        self.width = width
        self.height = height
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: PanelPoint(x: x, y: y), width: width, height: height)
    }

    /// Left edge.
    public var minX: Double { origin.x }
    /// Right edge.
    public var maxX: Double { origin.x + width }
    /// **Top** edge — the smaller `y`, because `y` grows downward.
    public var minY: Double { origin.y }
    /// **Bottom** edge — the larger `y`.
    public var maxY: Double { origin.y + height }

    /// The middle of the rectangle. This is the point guidance aims the finger at.
    public var center: PanelPoint {
        PanelPoint(x: origin.x + width / 2, y: origin.y + height / 2)
    }

    /// Whether `point` falls inside the rectangle, edges included.
    public func contains(_ point: PanelPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

// MARK: - PixelSize

/// The pixel dimensions of a source image.
///
/// This is the **only** place a pixel count appears in the contract, and it
/// describes an image's *size* — never a *position*. Positions are always
/// `PanelPoint`. See rule 5 in `COORDINATES.md`.
public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
