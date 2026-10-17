# Experience — ContourFeedback

> Everything the user perceives that is not on screen.

The person using Contour is not looking at the phone. Haptics, audio, and speech
*are* the interface. If this half is wrong, the other two teams' work is
invisible — literally.

**Leads:** Ashwanth, Nancy, Anushka · **Juniors:** Karan, Rishika, Asav

Experience owns three packages — `ContourFeedback`, [`ContourUI`](../ContourUI/README.md)
and [`ContourMocks`](../ContourMocks/README.md) — plus the `Harness`. This README
covers `ContourFeedback`.

## What you own here

`Packages/ContourFeedback`. You do not own detection or live tracking. You own
what the guidance *feels* like, and the four outcome signals.

**You still cannot `import ContourUI` from here**, even though the same team owns
it. The isolation rule is about what links together, not about who writes it;
`ContourApp` is where the two meet. If you want a type in both, it belongs in
`ContourCore`.

## Lanes

| Lane | Owner | Files |
|---|---|---|
| **Haptics** | Karan | `HapticEngineManager.swift`, `HapticPlayer.swift`, `ProximityHaptics.swift`, `GuidanceModel.swift` (models, `GuidanceTuning`, directional hint, `ChosenGuidanceModel`) |
| **Audio & Speech** | Rishika | `DirectionalAudio.swift`, `DirectionalAudioEngine.swift`, `ToneEngine.swift`, `SpeechQueue.swift`, `AudioSessionConfig.swift` |
| **Outcome Signals & Harness** *(officers)* | Ashwanth, Nancy, Anushka | `OutcomeAnnouncer.swift`, `Earcon.swift`, `LiveFeedbackEngine.swift`, `Harness/` |

`GuidanceModel.swift` is shared ground: the bake-off is a whole-team exercise,
but `ChosenGuidanceModel.kind` sits with Haptics because that lane lives with the
consequence. `OutcomeAnnouncer` says *what* to speak; `SpeechQueue` decides
whether it gets said — that split is why they are in different lanes.

## Your contract

```swift
public protocol FeedbackEngine: Sendable {
    func present(_ state: GuidanceState) async
}
```

One method, no return value. `GuidanceState` carries an optional
`GuidanceVector` (a unit `direction` plus a `normalizedDistance`) and an optional
terminal `OutcomeSignal`.

**`present(_:)` is called at camera rate.** Start an effect and return — never
`await` the full duration of a haptic pattern or an utterance, or you will stall
the frame stream behind you.

### The four outcomes, and only four

```swift
public enum OutcomeSignal: Sendable {
    case arrived        // the one happy ending
    case lostTracking   // tracking dropped; the user must re-aim
    case notFound       // the control is not on this panel; nothing is broken
    case lowConfidence  // found something, not sure enough to send a finger to it
}
```

That list is closed, which is exactly why you can build your whole vocabulary
before Surface Understanding and Tracking have working code. Adding a fifth case
is a `ContourCore` change and needs the leads of all three teams after the Week 2
freeze.

`notFound` and `lowConfidence` are easy to conflate and must not feel the same.
"There is no defrost button on this microwave" and "I think I see one but I
would be guessing" send the user to completely different next actions.

## You are not blocked by anyone

Run the Harness:

```bash
open Contour.xcworkspace     # then the `Harness` scheme, My Mac
```

macOS app. No iPhone, no camera, no tracking. Sliders for fingertip x/y, a
picker for tracking quality, a target picker, four buttons for the four
outcomes, and a "Walk to target" replay of the deterministic mock approach.

An engine picker switches between the printing mock and `LiveFeedbackEngine`
at runtime, with a guidance-model picker and toggles for the tone, speech and
the directional hint. Switching stops the old engine first. A Mac has no
haptics, but the tone, earcons and speech all play there.

Then put on a blindfold and have someone else drive the sliders. That is the
actual test, and you can run it in Week 1.

## Weeks 2–3 (Sep 21 – Oct 2)

From the project timeline, your deliverables:

- [ ] **Run the guidance model bake-off (Week 2) and pick one** → `GuidanceModel` *(Haptics, whole team)*
  Both candidates are built (`continuousProximity`, `pulsedProximity`) and
  switchable in the Harness and the Haptics debug screen. `ChosenGuidanceModel.kind`
  is **provisionally** `continuousProximity`; the blindfold runs are still to do —
  protocol and empty results table in [`docs/decisions/guidance-model.md`](../../docs/decisions/guidance-model.md).
- [x] **Prototype proximity haptics** → `ProximityHaptics` *(Haptics)*
  Pulses 600 ms → 70 ms, intensity 0.35 → 1, plus a sustained buzz for the
  continuous model. Numbers in `GuidanceTuning`; on-phone tuning is #118.
- [x] **Prototype directional audio** → `DirectionalAudio`, `SpeechQueue` *(Audio & Speech)*
  Pan from dx, pitch from −dy (up is higher), louder when closer; the tone ducks
  under speech; one shared `AudioSessionConfig`.
- [ ] **Define success and lost-tracking feedback with Design** → `OutcomeAnnouncer` *(Outcome Signals & Harness)*
  All four outcomes have haptics, an earcon and a spoken line. v1 spec in
  [`docs/decisions/outcome-signals.md`](../../docs/decisions/outcome-signals.md),
  **to be confirmed with Design (Kaylee)**.

### Status

| Piece | State |
|---|---|
| `LiveFeedbackEngine` | Live: model + tone + speech + optional directional hint. `LiveFeedbackEngine(model:audio:speech:directionalHint:)`, `stop()` ends a session. |
| Guidance models | Continuous (sustained buzz, throbs near the target) and pulsed. Provisional pick: continuous. |
| Directional audio | Live. One `ToneEngine` behind `DirectionalAudio` and the debug screen's `DirectionalAudioEngine`. |
| Speech | `SpeechQueue` speaks outcome lines; `activityUpdates()` drives ducking. |
| Outcome signals | Haptics + earcon + speech for all four; notFound ≠ lowConfidence on every channel. Pending Design sign-off. |
| Directional haptic hint | Built, off by default (#119). Needs a blindfold comparison. |
| Audio session | `AudioSessionConfig.configure()` once at launch; players follow its events. |
| Still to do | Blindfold bake-off (#54), on-phone haptics tuning (#118), Design sign-off on outcomes (#55), on-device ducking check (#114). |

These are four of Experience's six Weeks 2–3 deliverables; the other two are in
[`ContourUI`](../ContourUI/README.md). That is a lot for one team — the lanes
exist so it is four parallel jobs rather than one queue.

The bake-off is a **gate**, not a task: *"End of Week 2: interfaces and
coordinate convention frozen. Guidance model chosen from the bake-off."* Whatever
you pick, the rest of the project builds around. Run it early in Week 2 and use
the Harness to run it — you do not need working tracking to compare models.

**Checkpoint:** we can show how movement is communicated, independently of
whether anything is actually being tracked.

## Coordinates — read this first

`GuidanceState.vector.direction` is in **normalized panel space**: `+dx` is
right, **`+dy` is DOWN**.

**A direction of `(0, -1)` means "move the finger UP the panel."** Get this
backwards and every user goes the wrong way — and they cannot see that they are
going the wrong way. This is the single highest-consequence bug available to
your team.

`normalizedDistance` is `0` on target and `1` at the opposite corner of the
panel, normalized against the diagonal so intensity means the same thing on a
microwave and a lift plate. It can exceed `1` when the finger is off the panel.

Full convention: [`../ContourCore/COORDINATES.md`](../ContourCore/COORDINATES.md).

## Files

| File | What goes in it |
|---|---|
| `LiveFeedbackEngine.swift` | The conformance. Routes a `GuidanceState` to the channels below. |
| `GuidanceModel.swift` | The bake-off: candidate models, every tuning number, the directional hint, and the one you pick. |
| `ProximityHaptics.swift` | How close, as something you feel: the pulses. |
| `HapticPlayer.swift`, `HapticEngineManager.swift` | Pulses, the sustained buzz and taps, through one haptic engine. |
| `DirectionalAudio.swift` | Which way, as something you hear. |
| `ToneEngine.swift`, `DirectionalAudioEngine.swift` | The one AVAudioEngine graph, and the debug screen's face on it. |
| `OutcomeAnnouncer.swift`, `Earcon.swift` | The four terminal signals, agreed with Design. |
| `SpeechQueue.swift` | Whether an utterance is said now, later, or dropped as stale. |
| `AudioSessionConfig.swift` | The one audio-session setup, and its interruption / route-change events. |

Keep the public signatures — other code compiles against them.

## Working

```bash
cd Packages/ContourFeedback
swift test          # seconds, no simulator, no signing
```

Feedback is more testable than it sounds. Assert on the **pattern you would hand
to Core Haptics** — event times, intensities, sharpness — not on what it feels
like. A test that pins "distance 0.8 produces pulses 400 ms apart" catches a
regression that your fingers will not.

## Rules

- This package's **source** depends on **`ContourCore` and nothing else**. Not on
  SurfaceUnderstanding, not on Tracking, not on ContourUI — same-team ownership
  does not change that — and not on ContourMocks.
- This package's **tests** may also use **`ContourMocks`**.
  `Scripts/check-dependencies.sh` enforces both halves in CI.
- `ContourCore` is **frozen at the end of Week 2**. `GuidanceState` is your whole
  world — if it is missing something you need, say so in Week 1 or Week 2.
- Design (Kaylee) owes you the state-by-state feel spec. Weeks 2–3 list it as a
  joint deliverable; go and get it rather than waiting for it.
