import ContourCore
import Foundation

/// Completes one axis before switching. Text and speech consume the same decision.
struct ExperienceDirectionInstruction: Sendable {
    private(set) var text = "Press Start to begin."
    private(set) var voiceGuidance: ExperienceVoiceGuidance = .paused

    private enum Direction: String, Equatable, Sendable {
        case left, right, up, down

        var isHorizontal: Bool { self == .left || self == .right }

        func phrase(near: Bool) -> String {
            switch self {
            case .left: return near ? "A little to the left." : "Move left."
            case .right: return near ? "A little to the right." : "Move right."
            case .up: return near ? "A little upward." : "Move up."
            case .down: return near ? "A little downward." : "Move down."
            }
        }
    }

    private var direction: Direction?
    private var candidate: Direction?
    private var candidateSince = 0.0
    private var previousTime: Double?
    private var near = false

    mutating func update(_ vector: GuidanceVector, at time: Double) {
        guard time.isFinite, vector.normalizedDistance.isFinite,
              vector.normalizedDistance >= 0,
              vector.direction.dx.isFinite, vector.direction.dy.isFinite else {
            self = Self()
            text = "Guidance paused."
            return
        }
        guard previousTime.map({ time > $0 }) ?? true else { return }
        // Arrival is always based on the actual position, never prediction.
        if vector.normalizedDistance == 0 {
            self = Self()
            text = "On target."
            voiceGuidance = .slowly
            return
        }
        let remaining = SIMD2(vector.direction.dx, vector.direction.dy) * vector.normalizedDistance
        previousTime = time
        if vector.normalizedDistance <= 0.25 { near = true }
        if vector.normalizedDistance >= 0.30 { near = false }

        // Lock the selected axis until its actual remaining offset is almost
        // zero. Never switch merely because the other axis becomes larger.
        // This tolerance uses distance-scaled offsets, not unit-vector components.
        let deadZone = 0.02
        let horizontal: Direction = remaining.x >= 0 ? .right : .left
        let vertical: Direction = remaining.y >= 0 ? .down : .up
        if abs(remaining.x) <= deadZone && abs(remaining.y) <= deadZone {
            direction = nil
            candidate = nil
            text = "Move slowly."
            voiceGuidance = .slowly
            return
        }
        guard let current = direction else {
            let initial = abs(remaining.x) >= abs(remaining.y) ? horizontal : vertical
            direction = initial
            text = initial.phrase(near: near)
            voiceGuidance = .direction(.init(rawValue: initial.rawValue)!, near: near)
            return
        }
        let currentRemaining = current.isHorizontal ? remaining.x : remaining.y
        let otherRemaining = current.isHorizontal ? remaining.y : remaining.x
        let actualSameAxis = current.isHorizontal ? horizontal : vertical
        let otherDirection = current.isHorizontal ? vertical : horizontal
        let reversed = abs(currentRemaining) > deadZone && actualSameAxis != current
        let desired: Direction
        if reversed {
            // Correct an observed overshoot; never anticipate a reversal.
            desired = actualSameAxis
        } else if abs(currentRemaining) <= deadZone && abs(otherRemaining) > deadZone {
            desired = otherDirection
        } else {
            desired = current
        }
        if desired == current {
            candidate = nil
        } else if candidate != desired {
            candidate = desired
            candidateSince = time
        } else if time - candidateSince >= 0.12 {
            // Confirm alignment or a real overshoot briefly to reject jitter.
            direction = desired
            candidate = nil
        }
        text = (direction ?? current).phrase(near: near)
        voiceGuidance = .direction(.init(rawValue: (direction ?? current).rawValue)!, near: near)
    }
}

