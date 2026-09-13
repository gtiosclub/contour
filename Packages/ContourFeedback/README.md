# Feedback / Guidance — Team 3

> Everything the user perceives that is not on screen.

The person using Contour is not looking at the phone. Haptics, audio, and speech
*are* the interface. If your half is wrong, the other three teams' work is
invisible — literally.

## What you own

`Packages/ContourFeedback` — and nothing else. You do not own detection, live
tracking, or the camera UI. You own what the guidance *feels* like, and the four
outcome signals.

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
before Teams 1 and 2 have working code. Adding a fifth case is a `ContourCore`
change and needs all four leads after the Week 2 freeze.

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

To feel your own engine instead of the printing mock, change one line in
`Harness/Harness/HarnessApp.swift`:

```swift
import ContourFeedback
@State private var model = HarnessModel(engine: LiveFeedbackEngine())
```

Then put on a blindfold and have someone else drive the sliders. That is the
actual test, and you can run it in Week 1.

## Weeks 2–3 (Sep 21 – Oct 2)

From the project timeline, your deliverables:

- [ ] **Run the guidance model bake-off (Week 2) and pick one** → `GuidanceModel`
- [ ] **Prototype proximity haptics** → `ProximityHaptics`
- [ ] **Prototype directional audio** → `DirectionalAudio`
- [ ] **Define success and lost-tracking feedback with Design** → `OutcomeAnnouncer`

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
| `GuidanceModel.swift` | The bake-off: candidate models and the one you pick. |
| `ProximityHaptics.swift` | How close, as something you feel. |
| `DirectionalAudio.swift` | Which way, as something you hear. |
| `OutcomeAnnouncer.swift` | The four terminal signals, agreed with Design. |

Every body is `fatalError("unimplemented — owned by Team 3 (ContourFeedback)")`.
Replace the bodies, keep the signatures.

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

- This package depends on **`ContourCore` and nothing else**. Not on
  SurfaceUnderstanding, not on Tracking, not on ContourUI, not on ContourMocks.
  `Scripts/check-dependencies.sh` enforces it in CI.
- `ContourCore` is **frozen at the end of Week 2**. `GuidanceState` is your whole
  world — if it is missing something you need, say so in Week 1 or Week 2.
- Design owes you the state-by-state feel spec. Weeks 2–3 list it as a joint
  deliverable; go and get it rather than waiting for it.
