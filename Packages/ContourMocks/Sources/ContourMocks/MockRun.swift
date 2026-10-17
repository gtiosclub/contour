//
//  MockRun.swift
//  ContourMocks — Experience / Mocks & Integration
//
//  A script for one fake reach: where the fingertip starts, which button it
//  heads for, how long it takes, and whether tracking drops out on the way.
//  `MockTrackingSource(run:map:)` plays it at 30 Hz.
//
//  Every position is a pure function of (run, tick, target): ease-in-out
//  straight line, a fixed sine wobble, an optional overshoot, then a hold on
//  the target. No randomness, no clock — timestamps count from a fixed epoch.
//
//  COORDINATES: normalized panel space, (0,0) top-left, (1,1) bottom-right,
//  y DOWNWARD. See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

/// A deterministic script for a mock fingertip run toward one button.
public struct MockRun: Hashable, Sendable {

    /// Frames per second the run is sampled and streamed at.
    public static let framesPerSecond = 30

    /// Peak sideways wobble, in panel units, perpendicular to the path.
    public static let wobbleAmplitude = 0.01

    /// Full wobble cycles over the travel phase. Whole cycles, so the wobble
    /// is exactly zero at the start and on arrival.
    public static let wobbleCycles = 2.0

    /// Where the fingertip starts.
    public var start: PanelPoint

    /// The button the fingertip heads for, looked up in the map it is played
    /// against. The fingertip ends on that button's `bounds.center`.
    public var targetButtonID: UUID

    /// Seconds from `start` to arriving on the target.
    public var duration: TimeInterval

    /// Seconds the fingertip then holds on the target. Issue #12: 2 s.
    public var hold: TimeInterval

    /// Seconds since the start of the run during which tracking is lost:
    /// quality `.lost`, fingertip `nil`. `nil` means no dropout.
    public var dropout: Range<TimeInterval>?

    /// How far past the target the fingertip travels before coming back, in
    /// panel units along the path. `0` is a straight arrival.
    public var overshoot: Double

    public init(
        start: PanelPoint,
        targetButtonID: UUID,
        duration: TimeInterval,
        hold: TimeInterval = 2,
        dropout: Range<TimeInterval>? = nil,
        overshoot: Double = 0
    ) {
        precondition(duration > 0, "a MockRun needs a positive duration")
        precondition(hold >= 0, "a MockRun cannot hold for negative time")
        self.start = start
        self.targetButtonID = targetButtonID
        self.duration = duration
        self.hold = hold
        self.dropout = dropout
        self.overshoot = overshoot
    }

    // MARK: Presets

    /// Top-left corner region -> keypad "Start" (bottom-right), 2 s, no dropout.
    public static let straight = MockRun(
        start: PanelPoint(x: 0.12, y: 0.14),
        targetButtonID: MockSurfaceMaps.KeypadButton.start.id,
        duration: 2
    )

    /// As `straight`, but the fingertip passes 0.1 beyond the target and returns.
    public static let overshoot = MockRun(
        start: PanelPoint(x: 0.12, y: 0.14),
        targetButtonID: MockSurfaceMaps.KeypadButton.start.id,
        duration: 2,
        overshoot: 0.1
    )

    /// As `straight`, with 0.5 s of lost tracking in the middle of the reach
    /// (0.75 s ..< 1.25 s, i.e. ticks 23...37 — fifteen frames).
    public static let withDropout = MockRun(
        start: PanelPoint(x: 0.12, y: 0.14),
        targetButtonID: MockSurfaceMaps.KeypadButton.start.id,
        duration: 2,
        dropout: 0.75..<1.25
    )

    /// The presets by name, for pickers and parameterized tests.
    public enum Preset: String, CaseIterable, Hashable, Sendable {
        case straight
        case overshoot
        case withDropout

        public var run: MockRun {
            switch self {
            case .straight: .straight
            case .overshoot: .overshoot
            case .withDropout: .withDropout
            }
        }

        /// A short human name, e.g. for a segmented picker.
        public var title: String {
            switch self {
            case .straight: "Straight"
            case .overshoot: "Overshoot"
            case .withDropout: "Dropout"
            }
        }
    }

    // MARK: Ticks

    /// Ticks spent travelling. Arrival is at tick `travelTicks`.
    public var travelTicks: Int {
        max(1, Int((duration * Double(Self.framesPerSecond)).rounded()))
    }

    /// The last tick. The run emits `lastTick + 1` frames: travel, then hold.
    public var lastTick: Int {
        travelTicks + Int((hold * Double(Self.framesPerSecond)).rounded())
    }

    /// Seconds since the start of the run at `tick`.
    public static func elapsed(atTick tick: Int) -> TimeInterval {
        Double(tick) / Double(framesPerSecond)
    }

    // MARK: Frames (pure)

    /// The frame at `tick`, heading for `target`. Pure: same inputs, same frame.
    ///
    /// `tick` is clamped to `0...lastTick`.
    public func frame(atTick tick: Int, target: PanelPoint, baseTimestamp: Date) -> TrackingFrame {
        let clamped = min(max(tick, 0), lastTick)
        let elapsed = Self.elapsed(atTick: clamped)
        let timestamp = baseTimestamp.addingTimeInterval(elapsed)

        if let dropout, dropout.contains(elapsed) {
            return .lost(at: timestamp)
        }

        return TrackingFrame(
            timestamp: timestamp,
            fingertip: fingertip(atTick: clamped, target: target),
            panel: MockRun.pose,
            trackingQuality: .good
        )
    }

    /// Every frame of the run, tick `0` through `lastTick`.
    public func frames(target: PanelPoint, baseTimestamp: Date) -> [TrackingFrame] {
        (0...lastTick).map { frame(atTick: $0, target: target, baseTimestamp: baseTimestamp) }
    }

    /// Where the fingertip is at `tick`, ignoring any dropout.
    public func fingertip(atTick tick: Int, target: PanelPoint) -> PanelPoint {
        guard tick < travelTicks else { return target }

        let progress = Double(max(tick, 0)) / Double(travelTicks)
        let path = start.vector(to: target)
        let length = path.magnitude

        // Fraction of the start->target line covered. 1 is on target.
        let along: Double
        if overshoot > 0, length > 0 {
            // Out to `1 + beyond` over the first 75%, back to 1 over the rest.
            let beyond = overshoot / length
            let split = 0.75
            if progress < split {
                along = Self.easeInOut(progress / split) * (1 + beyond)
            } else {
                along = 1 + beyond * (1 - Self.easeInOut((progress - split) / (1 - split)))
            }
        } else {
            along = Self.easeInOut(progress)
        }

        let wobble = Self.wobbleAmplitude * sin(2 * .pi * Self.wobbleCycles * progress)
        let sideways = PanelVector(dx: -path.dy, dy: path.dx).normalized ?? .zero

        return PanelPoint(
            x: start.x + path.dx * along + sideways.dx * wobble,
            y: start.y + path.dy * along + sideways.dy * wobble
        )
    }

    /// Smoothstep: 0 -> 1 with zero velocity at both ends.
    static func easeInOut(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A plausible pose: panel 40 cm in front of the camera, square on.
    /// Same as `MockTrackingSource`'s `.good` pose.
    static let pose = PanelPose(
        column0: SIMD4(1, 0, 0, 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0),
        column3: SIMD4(0, 0, -0.4, 1),
        confidence: 0.92
    )
}
