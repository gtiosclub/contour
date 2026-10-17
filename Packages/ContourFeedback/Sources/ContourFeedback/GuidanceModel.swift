//
//  GuidanceModel.swift
//  ContourFeedback — Experience / Haptics
//
//  Weeks 2–3 deliverable: "Run the guidance model bake-off (Week 2) and pick one."
//
//  ┌──────────────────────────────────────────────────────────────────────────┐
//  │  THIS IS A GATE, NOT A TASK.                                             │
//  │                                                                          │
//  │  "End of Week 2: interfaces and coordinate convention frozen. Guidance    │
//  │  model chosen from the bake-off."                                        │
//  │                                                                          │
//  │  Whatever you pick here, the rest of the project builds around. Run the   │
//  │  bake-off in the Harness in Week 2 — you do not need working tracking to  │
//  │  compare models, and waiting for it costs you the gate.                   │
//  └──────────────────────────────────────────────────────────────────────────┘
//
//  A "guidance model" is the HAPTIC half of guidance: the mapping from a
//  GuidanceVector to what the user feels. Directional audio, speech and the
//  directional haptic hint are separate switches on LiveFeedbackEngine, so any
//  model can be felt with or without them. This enum is yours and nobody
//  outside this package reads it.
//
//  THE TWO CANDIDATES (#17)
//    continuousProximity  One sustained buzz, like an incoming call, that gets
//                         stronger and crisper as the finger closes in. In the
//                         last stretch it throbs, faster and faster, because a
//                         buzz near full strength cannot get much stronger and
//                         "almost there" still has to be felt. This is the
//                         sustained vibration testers asked for (#120).
//    pulsedProximity      ProximityHaptics' hot/cold pulses: soft and 600 ms
//                         apart at the edge of the panel, sharp and 70 ms apart
//                         on the button.
//  The starting list also had discreteDirectional (now the directional hint
//  switch, #119), continuousAudioField (now the audio switch) and
//  spokenCorrections (dropped: speech is the slowest channel — see SpeechQueue).
//
//  THE DIRECTIONAL HINT (#119), behind a switch, off by default
//  Hot/cold says how far, not which way. Without headphones, or in a loud
//  kitchen, nothing else says which way either. The hint fires an occasional
//  haptic correction for the dominant axis only — up, down, left or right —
//  rate-limited so it never chatters, and silent in the last stretch where the
//  proximity signal takes over. It plays on top of whichever model is running.
//
//  Both models play through one HapticPlayer and so one HapticEngineManager.
//  Switching models mid-run stops the old one first, and the player only ever
//  runs one guidance vibration at a time, so nothing is left buzzing.
//
//  EVERY TUNING NUMBER IS IN `GuidanceTuning`, right below. Change them there,
//  then re-run the tests that pin them.
//
//  COORDINATES: `direction` is panel space — +dy is DOWN.
//  See Packages/ContourCore/COORDINATES.md.
//

import ContourCore
import Foundation

// MARK: - Tuning

/// Every number that decides how guidance feels, in one place.
///
/// Ranges run from the far edge of the panel (`lowerBound`) to the target
/// (`upperBound`). Distances are `GuidanceVector.normalizedDistance`, clamped to
/// `0...1`, so a finger off the panel feels like the edge of it.
struct GuidanceTuning {
    private init() {}

    // Pulsed — ProximityHaptics.

    /// Time between pulses on the target and at the edge of the panel, ms.
    static let pulseIntervalOnTarget = 70.0
    static let pulseIntervalAtEdge = 600.0
    /// Each pulse buzzes for half its interval, at most this long, so even the
    /// fastest pulses have a gap you can feel.
    static let pulseWidthCap = Duration.milliseconds(60)
    /// Pulse strength and crispness, edge ... target. The floor keeps the far
    /// edge feelable (#53 asks for at least about 0.2).
    static let pulseIntensity = 0.35...1.0
    static let pulseSharpness = 0.3...0.9

    // Continuous — the sustained buzz.

    /// Buzz strength and crispness, edge ... target. Same floor as the pulses.
    static let buzzIntensity = 0.35...1.0
    static let buzzSharpness = 0.2...0.8
    /// Closer than this, the buzz throbs. 0 turns the throb off.
    static let throbZone = 0.12
    /// One full strong-weak throb cycle on the target and at the zone's edge, ms.
    static let throbPeriodOnTarget = 120.0
    static let throbPeriodAtZoneEdge = 400.0
    /// The weak half of a throb, as a fraction of the strong half. Never 0: the
    /// buzz stays sustained, it does not turn into taps.
    static let throbDip = 0.5

    // Directional hint (#119).

    /// The same direction is repeated at most this often, seconds.
    static let hintRepeatInterval = 1.5
    /// Never two hints closer together than this, even when the direction
    /// changes, seconds.
    static let hintMinimumGap = 0.4
    /// After an outcome, wait this long before hinting again, so a hint never
    /// cuts off the outcome's taps, seconds.
    static let hintHoldAfterOutcome = 1.5
    /// Closer than this, no hint: the proximity signal is doing the work.
    static let hintDeadZone = 0.05
    /// To switch axis, the other axis must be this much bigger than the one the
    /// last hint used, so a diagonal approach doesn't flip-flop.
    static let hintAxisSwitchRatio = 1.25
    /// Gap between the taps of one hint, ms.
    static let hintTapSpacing = 80

    /// `0...1`, so a finger off the panel feels like the edge. NaN reads as the edge.
    static func clamped(_ distance: Double) -> Double {
        distance.isNaN ? 1 : min(max(distance, 0), 1)
    }

    /// `range` at this closeness: `lowerBound` at 0, `upperBound` at 1.
    static func value(in range: ClosedRange<Double>, closeness: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * closeness
    }
}

// MARK: - The models

/// A candidate way of turning guidance into perception, for the Week 2 bake-off.
///
/// Deliberately shallow — the point of the bake-off is to feel these, not to
/// read about them. Run them through the Harness blindfolded, and delete the
/// ones that lose.
public enum GuidanceModelKind: String, Hashable, Sendable, CaseIterable {

    /// One sustained buzz that strengthens as you close in and throbs faster in
    /// the last stretch. Feels like an incoming call that gets more urgent.
    case continuousProximity

    /// Pulse rate and strength encode distance; nothing encodes direction. The
    /// user sweeps and follows the warmth.
    case pulsedProximity

    /// A short name for pickers and logs.
    public var displayName: String {
        switch self {
        case .continuousProximity: "Continuous buzz"
        case .pulsedProximity: "Pulses"
        }
    }

    /// Build this model on `player`, so it shares one haptic engine with the
    /// outcome signals and with whatever model ran before it.
    func makeModel(player: HapticPlayer) -> any MainActorGuidanceModel {
        switch self {
        case .continuousProximity: ContinuousProximityModel(player: player)
        case .pulsedProximity: PulsedProximityModel(player: player)
        }
    }
}

/// The thing a guidance model must be able to do.
///
/// One state in, one perceptual frame out. Keeping this separate from
/// `LiveFeedbackEngine` is what lets you swap models during the bake-off without
/// rewiring anything.
public protocol GuidanceModel: Sendable {

    /// Which candidate this is.
    var kind: GuidanceModelKind { get }

    /// Render one moment of guidance.
    ///
    /// Must return promptly — it is called at camera rate. Start effects, do not
    /// await them. A state with no vector, or a terminal one, goes quiet.
    func render(_ state: GuidanceState) async

    /// Silence this model. Must be safe to call when idle, and must leave
    /// nothing vibrating — it is what runs before another model takes over.
    func stop() async
}

/// A model whose work is main-actor and synchronous underneath.
///
/// `render` and `stop` are each one hop to this. LiveFeedbackEngine calls it
/// directly, so a whole frame — model, tone, hint, outcome — is applied in one
/// step and a later frame can never overtake an earlier one (an outcome's
/// "stop" landing before the frame it followed would leave a buzz on).
protocol MainActorGuidanceModel: GuidanceModel {
    @MainActor func apply(_ state: GuidanceState)
    @MainActor func silence()
}

/// One sustained buzz, described independently of Core Haptics.
struct SustainedBuzz: Hashable, Sendable {

    /// How strong, `0...1`.
    var intensity: Double

    /// How crisp, `0...1`.
    var sharpness: Double

    /// One full strong-weak cycle, or `nil` for a steady buzz.
    var throbPeriod: Duration?
}

/// The sustained, phone-call-style candidate. See the file header.
public struct ContinuousProximityModel: MainActorGuidanceModel {

    public let kind = GuidanceModelKind.continuousProximity
    private let player: HapticPlayer

    public init() {
        self.init(player: HapticPlayer())
    }

    init(player: HapticPlayer) {
        self.player = player
    }

    public func render(_ state: GuidanceState) async {
        await apply(state)
    }

    public func stop() async {
        await silence()
    }

    @MainActor
    func apply(_ state: GuidanceState) {
        guard !state.isTerminal,
              let distance = state.vector?.normalizedDistance,
              let buzz = Self.buzz(forDistance: distance)
        else {
            player.stopPulsing()
            return
        }
        player.sustain(buzz)
    }

    @MainActor
    func silence() {
        player.stopPulsing()
    }

    /// The buzz at a given distance, or `nil` when the distance isn't a number.
    ///
    /// Pure and synchronous on purpose — this is the part you can unit-test.
    static func buzz(forDistance distance: Double) -> SustainedBuzz? {
        guard !distance.isNaN else { return nil }
        let clamped = GuidanceTuning.clamped(distance)
        let closeness = 1 - clamped
        return SustainedBuzz(
            intensity: GuidanceTuning.value(in: GuidanceTuning.buzzIntensity, closeness: closeness),
            sharpness: GuidanceTuning.value(in: GuidanceTuning.buzzSharpness, closeness: closeness),
            throbPeriod: throbPeriod(forDistance: clamped)
        )
    }

    /// Faster as the finger closes in; `nil` (steady) outside the throb zone.
    private static func throbPeriod(forDistance distance: Double) -> Duration? {
        let zone = GuidanceTuning.throbZone
        guard zone > 0, distance < zone else { return nil }
        let throughZone = distance / zone   // 0 on the target ... 1 at the zone's edge
        let onTarget = GuidanceTuning.throbPeriodOnTarget
        let atEdge = GuidanceTuning.throbPeriodAtZoneEdge
        return .milliseconds(Int((onTarget + (atEdge - onTarget) * throughZone).rounded()))
    }
}

/// The hot/cold pulses candidate: ProximityHaptics, as a model.
public struct PulsedProximityModel: MainActorGuidanceModel {

    public let kind = GuidanceModelKind.pulsedProximity
    private let proximity: ProximityHaptics

    public init() {
        self.init(player: HapticPlayer())
    }

    init(player: HapticPlayer) {
        proximity = ProximityHaptics(player: player)
    }

    public func render(_ state: GuidanceState) async {
        await apply(state)
    }

    public func stop() async {
        await silence()
    }

    @MainActor
    func apply(_ state: GuidanceState) {
        if state.isTerminal {
            proximity.silence()
        } else {
            proximity.apply(state)
        }
    }

    @MainActor
    func silence() {
        proximity.silence()
    }
}

// MARK: - The directional hint

/// Which way the directional hint tells the finger to move.
///
/// Panel space: `.up` is NEGATIVE dy. See Packages/ContourCore/COORDINATES.md.
enum HintDirection: String, Hashable, Sendable, CaseIterable {
    case up, down, left, right
}

/// Occasional haptic corrections for the dominant axis (#119).
///
/// The mapping and the signatures are pure; the one piece of state is when the
/// last hint fired, measured on `GuidanceState.timestamp` so tests are
/// deterministic and a replayed walk feels the same every time.
struct DirectionalHint: Sendable {

    private var last: (direction: HintDirection, time: Date)?
    private var holdUntil: Date?

    /// The hint to fire for `state`, or `nil` to stay quiet: no vector, a
    /// terminal state, inside the dead zone, or too soon after the last one.
    mutating func next(for state: GuidanceState) -> HintDirection? {
        guard !state.isTerminal,
              let vector = state.vector,
              let direction = Self.direction(for: vector, previous: last?.direction)
        else { return nil }
        if let holdUntil, state.timestamp < holdUntil { return nil }
        if let last {
            let elapsed = state.timestamp.timeIntervalSince(last.time)
            let due = direction == last.direction
                ? GuidanceTuning.hintRepeatInterval
                : GuidanceTuning.hintMinimumGap
            // A clock that went backwards (a new session) counts as due. The
            // millisecond of slack absorbs Date's rounding.
            if elapsed >= 0 && elapsed < due - 0.001 { return nil }
        }
        last = (direction, state.timestamp)
        return direction
    }

    /// An outcome just played: forget the last hint and hold off for a moment.
    mutating func outcomeHappened(at time: Date) {
        last = nil
        holdUntil = time.addingTimeInterval(GuidanceTuning.hintHoldAfterOutcome)
    }

    /// The dominant axis of `vector`, or `nil` when there is no sensible hint.
    ///
    /// ⚠️ +dy is DOWN: a negative dy is `.up`.
    static func direction(for vector: GuidanceVector, previous: HintDirection?) -> HintDirection? {
        let dx = vector.direction.dx, dy = vector.direction.dy
        guard dx.isFinite, dy.isFinite, vector.normalizedDistance.isFinite,
              vector.normalizedDistance >= GuidanceTuning.hintDeadZone,
              dx != 0 || dy != 0
        else { return nil }

        let horizontal: HintDirection = dx < 0 ? .left : .right
        let vertical: HintDirection = dy < 0 ? .up : .down
        let ratio = GuidanceTuning.hintAxisSwitchRatio
        switch previous {
        case .left?, .right?:
            return abs(dy) > abs(dx) * ratio ? vertical : horizontal
        case .up?, .down?:
            return abs(dx) > abs(dy) * ratio ? horizontal : vertical
        case nil:
            return abs(dx) > abs(dy) ? horizontal : vertical
        }
    }

    /// What each direction feels like. Up and down are both two taps, told
    /// apart by contour and touch; left and right by count.
    ///
    ///     up     two crisp taps, rising     — a lift
    ///     down   two dull taps, falling     — a drop
    ///     left   one firm tap
    ///     right  three quick taps
    static func signature(for direction: HintDirection) -> [HapticEvent] {
        let spacing = GuidanceTuning.hintTapSpacing
        func tap(_ index: Int, _ intensity: Double, _ sharpness: Double) -> HapticEvent {
            HapticEvent(time: .milliseconds(index * spacing), intensity: intensity, sharpness: sharpness)
        }
        switch direction {
        case .up: return [tap(0, 0.5, 0.9), tap(1, 1.0, 0.9)]
        case .down: return [tap(0, 1.0, 0.15), tap(1, 0.5, 0.15)]
        case .left: return [tap(0, 0.8, 0.5)]
        case .right: return [tap(0, 0.7, 0.5), tap(1, 0.7, 0.5), tap(2, 0.7, 0.5)]
        }
    }
}

// MARK: - The decision

/// The model chosen at the end of Week 2.
///
/// Set this once the bake-off is decided, and record *why* in
/// docs/decisions/guidance-model.md. Every later argument about feel starts
/// from this decision.
public enum ChosenGuidanceModel {

    /// `nil` until the Week 2 gate. CI does not enforce that — your lead does.
    public static let kind: GuidanceModelKind? = nil

    /// What runs while `kind` is `nil`: the pulses the MVP shipped with.
    public static let fallback: GuidanceModelKind = .pulsedProximity

    /// `kind`, or `fallback` until it is set. What `LiveFeedbackEngine()` uses.
    public static var current: GuidanceModelKind { kind ?? fallback }
}
