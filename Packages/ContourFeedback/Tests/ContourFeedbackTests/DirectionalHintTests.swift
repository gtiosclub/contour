//
//  DirectionalHintTests.swift
//  ContourFeedbackTests — Experience / Haptics
//
//  Pins the directional haptic hint (#119): which way it says (with +dy DOWN),
//  what each direction feels like, and how rarely it fires. Time is the
//  states' timestamps, so none of this waits on a clock.
//

import ContourCore
import Foundation
import Testing
@testable import ContourFeedback

private func vector(_ dx: Double, _ dy: Double, distance: Double = 0.5) -> GuidanceVector {
    GuidanceVector(direction: PanelVector(dx: dx, dy: dy), normalizedDistance: distance)
}

private func state(_ dx: Double, _ dy: Double, at seconds: Double, distance: Double = 0.5) -> GuidanceState {
    GuidanceState(timestamp: Date(timeIntervalSince1970: seconds), vector: vector(dx, dy, distance: distance))
}

@Suite("Directional hint")
struct DirectionalHintTests {

    // MARK: Direction

    @Test("+dy is down: a target ABOVE the finger (negative dy) hints UP")
    func axisConvention() {
        #expect(DirectionalHint.direction(for: vector(0, -1), previous: nil) == .up)
        #expect(DirectionalHint.direction(for: vector(0, 1), previous: nil) == .down)
        #expect(DirectionalHint.direction(for: vector(-1, 0), previous: nil) == .left)
        #expect(DirectionalHint.direction(for: vector(1, 0), previous: nil) == .right)
    }

    @Test("only the dominant axis is hinted")
    func dominantAxisOnly() {
        #expect(DirectionalHint.direction(for: vector(0.3, -0.95), previous: nil) == .up)
        #expect(DirectionalHint.direction(for: vector(-0.95, 0.3), previous: nil) == .left)
        #expect(DirectionalHint.direction(for: vector(0.8, 0.6), previous: nil) == .right)
    }

    @Test("a diagonal doesn't flip-flop: switching axis needs a clear winner")
    func axisHysteresis() {
        let nearlyDiagonal = vector(0.69, -0.72)   // dy only a hair bigger
        #expect(DirectionalHint.direction(for: nearlyDiagonal, previous: nil) == .up)
        #expect(DirectionalHint.direction(for: nearlyDiagonal, previous: .right) == .right)
        #expect(DirectionalHint.direction(for: vector(0.5, -0.87), previous: .right) == .up)
    }

    @Test("no hint on the target, for a zero direction, or for nonsense")
    func noHint() {
        #expect(DirectionalHint.direction(for: vector(0, -1, distance: 0.02), previous: nil) == nil)
        #expect(DirectionalHint.direction(for: vector(0, 0), previous: nil) == nil)
        #expect(DirectionalHint.direction(for: vector(.nan, 1), previous: nil) == nil)
        #expect(DirectionalHint.direction(for: vector(0, 1, distance: .nan), previous: nil) == nil)
    }

    // MARK: Signatures

    @Test("each direction has its own signature")
    func signaturesAreDistinct() {
        let signatures = HintDirection.allCases.map(DirectionalHint.signature(for:))
        #expect(Set(signatures).count == HintDirection.allCases.count)
        #expect(signatures.allSatisfy { !$0.isEmpty && $0.count <= 3 }, "a hint is a glance, not a sentence")
    }

    @Test("up rises and is crisp; down falls and is dull")
    func upAndDownShapes() throws {
        let up = DirectionalHint.signature(for: .up)
        let down = DirectionalHint.signature(for: .down)
        #expect(try #require(up.last).intensity > (try #require(up.first)).intensity)
        #expect(try #require(down.last).intensity < (try #require(down.first)).intensity)
        #expect(up.map(\.sharpness).min()! > down.map(\.sharpness).max()!)
    }

    @Test("left and right differ in count")
    func leftAndRightCounts() {
        #expect(DirectionalHint.signature(for: .left).count != DirectionalHint.signature(for: .right).count)
    }

    // MARK: Rate limiting

    @Test("the same direction repeats at most every 1.5 s")
    func sameDirectionIsRateLimited() {
        var hint = DirectionalHint()
        #expect(hint.next(for: state(0, -1, at: 0)) == .up)
        #expect(hint.next(for: state(0, -1, at: 0.5)) == nil)
        #expect(hint.next(for: state(0, -1, at: 1.49)) == nil)
        #expect(hint.next(for: state(0, -1, at: 1.5)) == .up)
    }

    @Test("a change of direction fires sooner, but never within 0.4 s")
    func directionChangeHasAMinimumGap() {
        var hint = DirectionalHint()
        #expect(hint.next(for: state(0, -1, at: 0)) == .up)
        #expect(hint.next(for: state(1, 0, at: 0.2)) == nil)
        #expect(hint.next(for: state(1, 0, at: 0.4)) == .right)
    }

    @Test("terminal or vectorless states never hint")
    func quietStates() {
        var hint = DirectionalHint()
        let at = Date(timeIntervalSince1970: 0)
        #expect(hint.next(for: GuidanceState(timestamp: at, vector: nil)) == nil)
        #expect(hint.next(for: GuidanceState(timestamp: at, vector: vector(0, -1), outcome: .arrived)) == nil)
    }

    @Test("after an outcome, the hint holds off so it can't cut the outcome's taps short")
    func holdsOffAfterAnOutcome() {
        var hint = DirectionalHint()
        hint.outcomeHappened(at: Date(timeIntervalSince1970: 10))
        #expect(hint.next(for: state(0, 1, at: 10.5)) == nil)
        #expect(hint.next(for: state(0, 1, at: 11.5)) == .down)
    }
}
