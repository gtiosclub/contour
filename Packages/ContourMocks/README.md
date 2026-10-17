# ContourMocks — the shared fakes

> **Owned by Experience**, in the Mocks & Integration lane. From the timeline,
> Weeks 2–3: *"Mocks for all three interfaces, shipped by Monday Sep 21 so
> everyone has something to build against."*

One fake per protocol, so all three teams can build and test before any other
team has working code. This is what the app runs on until the real packages come
online, one at a time, in Weeks 4–5.

## How to reach these from your package

`import ContourMocks` in your package's **test target**. Every team package's
manifest already declares the dependency, so it just works:

```swift
import ContourMocks          // in Tests/, fine
@testable import Tracking
```

In `Sources/` it is an error, and `Scripts/check-dependencies.sh` fails the PR.
That asymmetry is the whole point: everybody tests against the fakes, nobody
ships them. `ContourApp` and `Harness` are the exception — they are the wiring
and may import anything, which is how the mock pipeline runs in the app on day
one.

## What is in here

| Type | Stands in for | Behaviour |
|---|---|---|
| `MockSurfaceUnderstanding` | Surface Understanding | Returns a hardcoded six-button microwave. Ignores the photo entirely. Can be made to throw. |
| `MockSurfaceMaps.microwaveKeypad` | Surface Understanding | The issue #12 keypad: a second canned map, with one icon-only (`nil`-label) button. |
| `MockTrackingSource` | Tracking / Spatial | Walks a fingertip from a start point to a target on a timer. Supports scripted dropouts. Can also play a `MockRun` at 30 Hz. |
| `MockRun` | — | A script for one reach: start, target button id, duration, optional dropout. Presets `.straight`, `.overshoot`, `.withDropout`. |
| `GuidanceMath` | — | The one place the fingertip-to-target geometry lives. `MockGuidance` and `MockGuidanceSource` both call it. |
| `MockGuidanceSource` | Tracking + guidance | `MockTrackingSource` chained through `GuidanceMath`: an `AsyncStream<GuidanceState>` at 30 Hz. |
| `PrintingFeedbackEngine` | Experience | Prints each `GuidanceState` and records it. An actor, so tests can read it mid-stream. |
| `MockGuidance` | *nobody* | Placeholder wiring: turns `TrackingFrame` + target into `GuidanceState`. See below. |
| `SeededGenerator` | — | SplitMix64. The only permitted source of variation. |

## ⚠️ Determinism is the product here

**Seeded, no randomness, fixed timestamps.** Same input, same output, on every
machine, every run. All three teams' tests depend on it.

That means, in this package: no `Double.random(in:)`, no `Date()`, no system
RNG. If you want variation, take it from `SeededGenerator` with an explicit seed.
If a reviewer cannot predict the output from reading the call site, it does not
belong here.

`ContourMocksTests` exists to protect this. If you change the canned microwave or
the walk, change those numbers deliberately and say so in the PR — you are
changing all three teams' fixtures.

## The canned microwave

```
       x=0                                  x=1
  y=0   +----------------------------------+
        |  [Popcorn ] [Beverage] [Defrost] |   <- y 0.18 ... 0.38
        |  [Add 30s ] [ Start  ] [ Stop  ] |   <- y 0.52 ... 0.72
  y=1   +----------------------------------+
```

Button ids are hardcoded, so you can assert against a specific one. Confidences
are deliberately uneven — `Defrost` is the scuffed one at `0.61`, so anything
filtering on per-button confidence has something to filter. Panel confidence is
`0.94`.

## The issue #12 keypad, `MockRun` and `MockGuidanceSource`

```swift
let source = MockGuidanceSource(run: .withDropout)           // keypad, target "Start"
for await state in source.states() {                         // 30 Hz; ends after a 2 s hold
    await engine.present(state)                              // any FeedbackEngine
}
let frames = MockTrackingSource(run: .overshoot).allFrames() // the same frames, no clock: for tests
```

```
       x=0                                  x=1
  y=0   +----------------------------------+
        |  [Popcorn] [Defrost] [  +30s  ]  |   <- y 0.20 ... 0.40
        |  [   ✕   ] [ Stop  ] [ Start  ]  |   <- y 0.55 ... 0.75
  y=1   +----------------------------------+
```

- **`microwaveKeypad` is in addition to `microwave`, not instead of it.** Other
  teams' tests pin `microwave` ("Defrost" at `0.61`, every button labelled), so
  it is unchanged. The keypad has Start `0.94`, Stop `0.91`, +30s `0.88`,
  Defrost `0.83`, Cancel `0.80`, Popcorn `0.72`. Cancel is an ✕ icon with a `nil`
  label, so reach it by id: `MockSurfaceMaps.keypadButton(.cancel)`.
- **A `MockRun`** eases in and out along a straight line to the target's centre,
  with a `0.01` sine wobble that is zero at both ends, then holds for 2 s.
  `.overshoot` goes `0.1` past and comes back. `.withDropout` loses tracking from
  0.75 s to 1.25 s (15 frames with quality `.lost` and a `nil` fingertip). Every
  frame is a pure function of the run and the tick. Streaming sleeps on a
  `ContinuousClock` until each tick's deadline, so it does not drift. The
  original linear walk, `MockTrackingSource(start:target:steps:...)`, is
  unchanged.
- **`GuidanceMath.compute(frame:target:)`** clamps distance to `0...1` and turns
  a `nil` fingertip into `.lostTracking`. `MockGuidance` uses the same math but
  keeps its old behaviour, because the pipeline and the Harness run on it
  today. That means unclamped distance off the panel, `.lowConfidence` below a
  pose-confidence floor, and "no guidance" (not `.lostTracking`) for a `nil`
  fingertip on a frame that is not `.lost`.
- `ContourApp` has a DEBUG-only `MockRunDebugView()` that plays the presets.

## `MockGuidance` is placeholder wiring, not a feature

Something has to turn a `TrackingFrame` plus a target into the `GuidanceState`
that `FeedbackEngine` consumes, or the Harness has nothing to emit and
`ContourApp` has nothing to wire. `MockGuidance` is the smallest thing that
does it: subtract two points, normalize, check for arrival.

It is deliberately naive — no smoothing, no hysteresis, no dwell time.
**Experience's Week 2 guidance-model bake-off is what replaces it.** It lives in
`ContourMocks` precisely so that deleting it breaks nothing but mocks.

## Rules

- Depends on **`ContourCore` and nothing else** — that is what makes it safe for
  all three teams' test targets to depend on at once without a cycle. It
  implements all three protocols without importing any team's package.
- Keep it deterministic.
- Review here is Experience **plus the leads**: it is the one package where a
  careless change turns three teams' suites red at the same time.
